# frozen_string_literal: true

module Simulation
  # One SQL statement an actor ran, in the order the scheduler saw it end.
  # sent numbers the statements in the order they went to PostgreSQL.
  # waited is true when the statement waited for a lock in PostgreSQL
  # while other actors went on.
  Step = Data.define(:sent, :actor, :sql, :binds, :outcome, :waited)

  # Runs actors so that the seed decides everything that real threads
  # would leave to chance (challenge 31).
  #
  # Each actor runs on its own thread with a database connection of its
  # own, because a transaction needs a session of its own. But only one
  # actor runs at a time. An actor runs Ruby until it is about to send an SQL
  # statement, and stops there. The scheduler then uses the seed to pick
  # which stopped actor sends its statement next. So with the same seed,
  # the same statements go to PostgreSQL in the same order, and get the
  # same answers.
  #
  # A statement can wait in PostgreSQL for a lock another actor holds. The
  # scheduler sees that in pg_locks and goes on with the other actors.
  # After each step it checks the waiting actors in a fixed order, and an
  # actor whose lock was granted finishes its statement before anyone else
  # runs.
  #
  # Deadlocks: PostgreSQL checks a waiting session for a deadlock once,
  # deadlock_timeout after it starts to wait, and refuses the session
  # that finds one. That check runs on PostgreSQL's clock, and on this
  # laptop it ran anywhere from 20 to 110 ms after a 20 ms timeout. So
  # which session is refused would depend on the clock. Instead, each time
  # an actor starts to wait, the scheduler waits for that check to happen:
  # with log_lock_waits on, PostgreSQL sends "still waiting for ..." to the
  # session as soon as the check finds no deadlock, and the deadlock error
  # if it finds one. Every check then happens at a known point, and the
  # actor that closes a cycle is always the one refused.
  class Scheduler
    Result = Data.define(:steps, :values)

    # A statement is run through the scheduler unless Rails runs it to
    # read the schema, which it does whenever its cache is cold, or it is
    # a BEGIN. Rails sends BEGIN just before the first statement of a
    # transaction, from inside whichever statement comes first, and a
    # schema read counts. So whether BEGIN came on its own or with the
    # next statement depended on what an earlier run left in the cache.
    # PostgreSQL takes a transaction's snapshot at its first statement,
    # not at BEGIN, so a BEGIN changes nothing another session can see,
    # and it is left out of the trace.
    UNGATED = %w[SCHEMA].freeze
    BEGIN_STATEMENT = /\ABEGIN\b/

    # Session settings for the actors' connections. The app's own
    # timeouts are on the real clock; here an actor may wait a long real
    # time for its turn, so they are turned off. They are put back after.
    # log_lock_waits and client_min_messages send the "still waiting"
    # line described above.
    SESSION = { 'lock_timeout' => '0', 'statement_timeout' => '0',
                'idle_in_transaction_session_timeout' => '0', 'deadlock_timeout' => '10ms',
                'log_lock_waits' => 'on', 'client_min_messages' => 'log' }.freeze
    STILL_WAITING = /\ALOG:  process \d+ still waiting for /

    TURN_TIMEOUT = 60
    POLL = 0.001

    # The clock starts here unless a start is given (Determinism).
    START = Time.utc(2026, 1, 1, 12)

    def initialize(seed:, start: START)
      @seed = seed
      @start = start
      @rng = Random.new(seed)
      @actors = []
      @by_thread = Concurrent::Map.new
    end

    def actor(name, &work)
      raise ArgumentError, "two actors named #{name}" if @actors.any? { |a| a.name == name }

      @actors << Actor.new(name, work)
    end

    def run
      check_the_pool
      @steps = []
      @sent = 0
      prepare_the_connections
      Determinism.with(seed: @seed, start: @start) do |determinism|
        @clock = determinism.clock
        determinism.sleeper = ->(seconds) { @by_thread[Thread.current].sleep_until(@clock.at + seconds.to_r) }
        ActiveSupport::Notifications.subscribed(Gate.new(self), 'sql.active_record') do
          @actor_threads = determinism.actor_threads
          start_actors
          loop_until_done
        end
      end
      Result.new(steps: @steps, values: @actors.to_h { |a| [a.name, a.value] })
    ensure
      @actors.each(&:stop)
      put_the_connections_back
    end

    # The actor on this thread, if it is one.
    def actor_on(thread) = @by_thread[thread]

    # The PostgreSQL process behind a connection of the pool.
    def pid_of(connection) = @pids[connection]

    # Called on the actor's own thread once its setup is done. From here
    # on, the thread reads the simulation's clock and generator. Not
    # before: opening a connection, and the first instrumented call on a
    # thread, draw random bytes, and whether they happen depends on what
    # earlier runs left in the pool.
    def enter(thread)
      @actor_threads << thread
    end

    private

    # An actor does not keep one connection: Rails' executor gives the
    # thread's connection back to the pool at the end of each request
    # (ActiveRecord::ConnectionAdapters::ConnectionPool::ExecutorHooks),
    # and the next request takes whichever one is free. So every
    # connection in the pool except the scheduler's own is opened and set
    # up here, before the run:
    #   - opening one during the run would draw random bytes on an actor's
    #     thread, and whether it happens depends on what earlier runs
    #     left in the pool;
    #   - each gets the session settings above, and a notice processor
    #     that hands "still waiting" to the actor whose thread runs the
    #     statement (libpq calls it on that thread);
    #   - the scheduler learns each one's PostgreSQL process, so it looks
    #     in pg_locks for the process of the connection the actor is using
    #     now.
    def prepare_the_connections
      observer
      # Every table's columns, so no run reads the schema mid-way and the
      # next one does not.
      ActiveRecord::Base.connection_pool.schema_reflection.load!(ActiveRecord::Base.connection_pool)
      pool = ActiveRecord::Base.connection_pool
      connections = Array.new(pool.size - 1) { pool.checkout }
      @pids = {}.compare_by_identity
      @prepared = connections.map do |connection|
        raw = connection.raw_connection
        @pids[connection] = raw.backend_pid
        before = SESSION.keys.index_with { |name| raw.exec("SHOW #{name}").getvalue(0, 0) }
        SESSION.each { |name, value| raw.exec("SET #{name} = '#{value}'") }
        others = raw.set_notice_processor { |message| notice(message, others) }
        # raw_connection turns lazy transactions off for good on that
        # connection; production has them on. Left off, some connections
        # would send BEGIN as a statement of its own and others inside the
        # next one, and which kind an actor gets depends on the pool's order.
        connection.enable_lazy_transactions!
        [raw, before, others]
      end
    ensure
      connections&.each { |connection| pool.checkin(connection) }
    end

    def put_the_connections_back
      @prepared&.each do |raw, before, others|
        before.each { |name, value| raw.exec("SET #{name} = '#{value}'") }
        raw.set_notice_processor(&others)
      end
      @prepared = nil
    end

    # PostgreSQL's LOG lines come only because of client_min_messages
    # above. "still waiting" tells the actor's scheduler a deadlock check
    # ran; the rest are dropped. Every other notice goes where it went
    # before.
    def notice(message, others)
      if message.match?(STILL_WAITING)
        @by_thread[Thread.current]&.checks&.push(:checked)
      elsif !message.start_with?('LOG:')
        others&.call(message)
      end
    end

    # An actor that cannot get a connection waits 5 s for one and then
    # fails, which looks like a bug in the code under test.
    def check_the_pool
      size = ActiveRecord::Base.connection_pool.size
      return if size > @actors.size

      raise ArgumentError, "#{@actors.size} actors and the scheduler need a pool of #{@actors.size + 1}; " \
                           "it is #{size} (include_context 'with a pool for a simulation')"
    end

    # Every thread is registered before any is awaited: an actor's first
    # stop must already find itself in the map.
    def start_actors
      @actors.each { |actor| @by_thread[actor.start(self)] = actor }
      @actors.each { |actor| await(actor) } # rubocop:disable Style/CombinableLoops
    end

    def loop_until_done
      until @actors.all?(&:done?)
        wake_granted
        wake_sleepers
        ready = @actors.select(&:ready?)
        if ready.empty?
          next if jump_to_the_next_wake

          wait_for_a_blocked_actor
          next
        end
        actor = ready[@rng.rand(ready.size)]
        @clock.advance(Determinism::TICK)
        actor.grant(@sent += 1)
        await(actor)
      end
    end

    # Waits until the actor stops at its next statement or ends, or until
    # its statement waits for a lock.
    def await(actor)
      deadline = monotonic + TURN_TIMEOUT
      loop do
        arrival = actor.arrivals.pop(timeout: POLL)
        return arrived(actor, arrival) if arrival
        return blocked(actor) if actor.pid && waiting_for_a_lock?(actor.pid)
        next unless monotonic > deadline

        raise "simulation seed #{@seed}: #{actor.name} did not stop within #{TURN_TIMEOUT}s, at:\n  " +
              Array(actor.backtrace).first(25).join("\n  ")
      end
    end

    def arrived(actor, arrival)
      finished = actor.finish_statement
      @steps << finished if finished
      actor.arrive(arrival)
    end

    # The statement waits in PostgreSQL. Wait for PostgreSQL's deadlock
    # check of it before anyone else goes on: either it found no deadlock
    # and said "still waiting", or it found one and the statement ended.
    def blocked(actor)
      actor.block
      deadline = monotonic + TURN_TIMEOUT
      until actor.checks.pop(timeout: POLL) || !actor.arrivals.empty?
        raise "simulation seed #{@seed}: no deadlock check for #{actor.name}" if monotonic > deadline
      end
    end

    # In a fixed order: an actor whose lock is now granted (or whose wait
    # ended in an error) finishes its statement now.
    def wake_granted
      @actors.each do |actor|
        next unless actor.blocked?
        next if waiting_for_a_lock?(actor.pid) && actor.arrivals.empty?

        actor.unblock
        await(actor)
      end
    end

    # A sleeper whose time has come is ready again, in a fixed order.
    def wake_sleepers
      @actors.each { |actor| actor.wake if actor.sleeping? && actor.wake_at <= @clock.at }
    end

    # Nothing can run, and someone sleeps: nothing can happen before the
    # earliest wake, so the clock goes straight there.
    def jump_to_the_next_wake
      sleepers = @actors.select(&:sleeping?)
      return false if sleepers.empty?

      @clock.move_to(sleepers.map(&:wake_at).min)
      true
    end

    # Every actor left is waiting on a lock. Only PostgreSQL can end that
    # (a deadlock check), so wait for it.
    def wait_for_a_blocked_actor
      deadline = monotonic + TURN_TIMEOUT
      until @actors.any? { |a| a.blocked? && (!a.arrivals.empty? || !waiting_for_a_lock?(a.pid)) }
        raise "simulation seed #{@seed}: every actor waits on a lock and none was freed" if monotonic > deadline

        sleep(POLL)
      end
    end

    def waiting_for_a_lock?(pid)
      observer.exec_params('SELECT 1 FROM pg_locks WHERE pid = $1 AND NOT granted LIMIT 1', [pid]).ntuples.positive?
    end

    def observer
      @observer ||= ActiveRecord::Base.connection.raw_connection
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Stops an actor's thread before each statement it sends. It is the
    # subscriber's start, which ActiveSupport calls before the statement
    # runs; finish records what the statement ended in.
    #
    # A statement that runs inside another one's event runs in the same
    # turn, and the step's text lists it first: "inner; outer".
    class Gate
      def initialize(scheduler)
        @scheduler = scheduler
      end

      def start(_name, _id, payload)
        actor = @scheduler.actor_on(Thread.current)
        return unless actor && gated?(payload)
        return actor.nested_start(payload[:sql]) if actor.inside_a_statement?

        actor.pid = @scheduler.pid_of(payload[:connection])
        actor.stop_before(payload[:sql], binds(payload))
      end

      def finish(_name, _id, payload)
        actor = @scheduler.actor_on(Thread.current)
        return unless actor && gated?(payload)

        actor.statement_ended(payload[:exception]&.first || payload[:row_count] || :ok)
      end

      private

      def gated?(payload)
        UNGATED.exclude?(payload[:name]) && !payload[:cached] && !payload[:sql].match?(BEGIN_STATEMENT)
      end

      def binds(payload)
        binds = payload[:type_casted_binds]
        binds = binds.call if binds.respond_to?(:call)
        Array(binds).map { |value| value.respond_to?(:value_for_database) ? value.value_for_database : value }
      end
    end

    # One actor: its thread, and where it stands.
    #   ready    stopped before a statement (or not yet started), waiting
    #            for its turn
    #   running  has the turn
    #   blocked  its statement waits for a lock in PostgreSQL
    #   done     its work returned or raised
    class Actor
      attr_reader :name, :arrivals, :checks, :value, :wake_at
      # The PostgreSQL process of the connection the actor uses now.
      attr_accessor :pid

      def initialize(name, work)
        @name = name
        @work = work
        @arrivals = Queue.new
        @checks = Queue.new
        @turn = Queue.new
        @state = :running
        @in_flight = nil
        @waited = false
        @depth = 0
        @nested = []
      end

      def ready? = @state == :ready
      def blocked? = @state == :blocked
      def sleeping? = @state == :sleeping
      def done? = @state == :done

      # The thread starts and stops before it does anything, so the first
      # thing every actor does is also picked by the seed.
      def start(scheduler)
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          @arrivals << [:ready]
          wait_for_turn
          run(scheduler)
        end
      end

      def backtrace = @thread&.backtrace

      def stop
        @thread&.join(5)
      end

      def grant(sent)
        @state = :running
        @sent = sent
        @turn << :go
      end

      def block
        @state = :blocked
        @waited = true
      end

      def unblock
        @state = :running
      end

      def wake
        @state = :ready
      end

      # --- on the scheduler's thread ---

      def arrive(arrival)
        kind, *rest = arrival
        case kind
        when :ready then @state = :ready
        when :statement then @in_flight = [*rest, nil]
                             @state = :ready
        when :sleep then @state = :sleeping
                         @wake_at = rest.first
        when :done then @state = :done
                        @value = rest.first
        end
      end

      # The statement in flight ended (the actor is past it); the step it
      # makes, or nil if it was the first stop.
      def finish_statement
        return nil unless @in_flight && @outcome_set

        sql, binds, = @in_flight
        sql = [*@nested_done, sql].join('; ')
        step = Step.new(sent: @sent, actor: @name, sql: sql, binds: binds, outcome: @outcome, waited: @waited)
        @in_flight = nil
        @outcome_set = false
        @waited = false
        step
      end

      # --- on the actor's thread ---

      def stop_before(sql, binds)
        @arrivals << [:statement, sql, binds]
        wait_for_turn
        @depth = 1
      end

      def inside_a_statement? = @depth.positive?

      def nested_start(sql)
        @depth += 1
        @nested << sql
      end

      def sleep_until(wake_at)
        @arrivals << [:sleep, wake_at]
        wait_for_turn
      end

      # A nested statement's end only closes it; the outer one's outcome
      # is the step's.
      def statement_ended(outcome)
        @depth -= 1
        return if @depth.positive?

        @outcome = outcome
        @nested_done = @nested
        @nested = []
        @outcome_set = true
      end

      private

      def wait_for_turn
        raise 'the scheduler never gave this actor its turn' unless @turn.pop(timeout: TURN_TIMEOUT)
      end

      def run(scheduler)
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveSupport::Notifications.instrumenter
          scheduler.enter(Thread.current)
          @value = @work.call
        end
        @arrivals << [:done, @value]
      rescue StandardError => e
        @arrivals << [:done, e]
      end
    end
  end
end

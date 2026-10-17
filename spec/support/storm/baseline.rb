# frozen_string_literal: true

require 'json'

module Storm
  # How many meal writes a second one client gets answered on this
  # machine right now, with nothing else running. The request storm's
  # floor for meal writes per second is a share of this (#131).
  #
  # One client signs up for a meal and leaves it again, over and over,
  # for two seconds. Those are the storm's most common writes, sent
  # through the same transport and Rack stack, under the same meal lock,
  # in the same kind of SERIALIZABLE transaction, from the same process
  # to the same database. So whatever makes this machine slow (other test
  # suites, a laptop on battery, a small CI runner) slows this client and
  # the storm alike.
  #
  # The meal is plan.baseline_meal. No client, settler or admin in the
  # storm writes to it, so a measurement after the storm finds the meal
  # as a measurement before it did.
  class Baseline
    Result = Struct.new(:rate, :conflicts, keyword_init: true) do
      def to_s
        format('%<rate>.1f meal writes/s (%<conflicts>d answered 409)', rate: rate, conflicts: conflicts)
      end
    end

    SECONDS = 2.0
    # The first requests on a new thread check out a connection and fill
    # caches. They are sent but not timed.
    WARMUP_PAIRS = 5
    # The API throttle allows 600 requests a minute from one address
    # (config/initializers/rack_attack.rb). A fast machine could send that
    # many in one measurement, so the address changes every 100 requests.
    REQUESTS_PER_ADDRESS = 100
    # A write refused with a 409 is sent again every RETRY_PAUSE seconds,
    # for up to GIVE_UP_AFTER seconds.
    #
    # With nothing else in this database, PostgreSQL still refuses every
    # write while a SERIALIZABLE transaction that has written something
    # stays open in another database on the same server (#218). That
    # transaction keeps Postgres from freeing its records of the
    # transactions that committed after it started. When the space for
    # them is full, Postgres keeps only a summary of the oldest ones, and
    # then it can no longer tell that the writers of the old versions of
    # this meal's row finished before this read began. It assumes a
    # conflict, and the reason code is "Canceled on identification as a
    # pivot, during write". Every try fails the same way until the other
    # transaction ends. On a laptop where other worktrees run their tests
    # against the same server, such a transaction lasts a few seconds.
    # The old limit, 10 tries in a row, used less than a second.
    RETRY_PAUSE = 0.1
    GIVE_UP_AFTER = 30.0

    def self.call(**)
      new(**).call
    end

    # network: the first three parts of an IPv4 address, such as
    # "10.8.0". Give each measurement its own, so the throttle never
    # counts two of them together.
    def initialize(plan:, transport:, network:, seconds: SECONDS, give_up_after: GIVE_UP_AFTER)
      @path = "/api/v1/meals/#{plan.baseline_meal.id}/residents/#{plan.residents.first.id}"
      @headers = { 'Authorization' => "Bearer #{plan.tokens.fetch(plan.residents.first.id)}" }
      @transport = transport
      @network = network
      @seconds = seconds
      @give_up_after = give_up_after
      @sent = 0
      @conflicts = 0
    end

    # On its own thread, the way a storm client runs, so it checks out a
    # connection of its own.
    def call
      Thread.new { measure }.value
    end

    private

    def measure
      WARMUP_PAIRS.times { write_pair }
      writes = 0
      started = now
      while now - started < @seconds
        write_pair
        writes += 2
      end
      Result.new(rate: writes / (now - started), conflicts: @conflicts)
    end

    def write_pair
      write(:post, { late: false, vegetarian: false })
      write(:delete, {})
    end

    # A 409 is sent again, as a client would. The count is shown in the
    # storm's summary. The time a conflict took stays in the measurement,
    # which can only lower the floor.
    def write(method, body)
      started = now
      loop do
        status, response = @transport.call(method, @path, @headers, JSON.generate(body), address)
        return if status == 200
        raise "baseline #{method} #{@path} answered #{status}: #{response.to_s[0, 300]}" unless status == 409

        @conflicts += 1
        break if now - started >= @give_up_after

        sleep(RETRY_PAUSE)
      end
      raise "baseline #{method} #{@path} answered 409 for #{@give_up_after} seconds in a row. " \
            "Open transactions on this server that have written something: #{open_writers}"
    end

    # The sessions on this Postgres server, in any database, inside a
    # transaction that has written something and has been open for more
    # than a second. One of them is the likely cause of a run of 409s
    # (see GIVE_UP_AFTER).
    def open_writers
      rows = ActiveRecord::Base.connection.select_rows(<<~SQL.squish)
        SELECT datname, pid, round(extract(epoch FROM now() - xact_start)::numeric, 1)
        FROM pg_stat_activity
        WHERE backend_xid IS NOT NULL AND pid <> pg_backend_pid() AND xact_start < now() - interval '1 second'
        ORDER BY xact_start
      SQL
      return 'none' if rows.empty?

      rows.map { |database, pid, open_for| "#{database} (pid #{pid}, open #{open_for}s)" }.join(', ')
    end

    def address
      @sent += 1
      "#{@network}.#{(@sent / REQUESTS_PER_ADDRESS) + 1}"
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

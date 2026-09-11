# frozen_string_literal: true

module Storm
  # Runs the storm: one Client per thread until the deadline, and beside
  # them the writers production has that are not phones:
  #
  #   - a settler, the nightly reconciliations:create, trying again and
  #     again the way the rake task in its own dyno would if it were run
  #     in a loop;
  #   - the nightly jobs, run the way Solid Queue runs them
  #     (ActiveJob::Base.execute, under the executor);
  #   - an admin, writing attendance and bills through the models without
  #     the meal lock, the way ActiveAdmin does (ADR 0003: the database
  #     triggers are what make that safe, and this is where that is put
  #     under load).
  #
  # Everything a thread does is logged; nothing is asserted here. The
  # Result carries the client entries, the background log, and the
  # problems the run itself saw (a thread that did not finish, a writer
  # that raised something no path expects). The spec and the rake task
  # decide what to do with them.
  class Run
    Result = Struct.new(:requests, :background, :problems, :meal_sockets, keyword_init: true) do
      def tally
        requests.group_by(&:action).transform_values { |list| list.map(&:status).tally }
      end

      def background_tally
        background.map { |who, outcome, name| [name || who, outcome.is_a?(Array) ? outcome.first : outcome] }.tally
      end

      def ok_writes
        requests.count { |e| Client::MEAL_WRITES.include?(e.action) && e.status == 200 }
      end

      def settlements
        background.count { |who, outcome, _| who == :settler && outcome == :settled } +
          requests.count { |e| e.action == :settle && e.status == 201 }
      end
    end

    JOBS = [RefreshBalancesJob, VerifyLedgerJob, SetMultipliersJob, EnsureRotationsJob].freeze

    # What an unlocked admin write may end in, besides success: a rule, a
    # unique index, a guard, the settled-meal trigger, a conflict, or a
    # lock wait that ran out. Anything else is a problem.
    ADMIN_REFUSALS = [
      ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotDestroyed,
      ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
    ].freeze
    TRIGGER_REFUSAL = /refused: meal \d+ is reconciled/

    JOIN_TIMEOUT = 90

    def self.call(**)
      new(**).call
    end

    def initialize(plan:, transport:, clients:, seconds:, seed:)
      @plan = plan
      @transport = transport
      @clients = clients
      @seconds = seconds
      @seed = seed
      @log = Queue.new
      @problems = []
    end

    def call
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @seconds
      clients = Array.new(@clients) do |index|
        Client.new(index: index, plan: @plan, transport: @transport, rng: Random.new(@seed + index),
                   deadline: @deadline)
      end
      threads = clients.map { |client| Thread.new { client.run } } + background_threads
      join(threads)
      Result.new(requests: clients.flat_map(&:log), background: Array.new(@log.size) { @log.pop },
                 problems: @problems, meal_sockets: clients.map(&:meal_sockets).reduce(Set.new, :|))
    end

    private

    def join(threads)
      threads.each_with_index do |thread, i|
        next unless thread.join(JOIN_TIMEOUT).nil?

        @problems << "thread #{i} did not finish within #{JOIN_TIMEOUT} seconds of the deadline (deadlock?)"
      end
    end

    def background_threads
      [Thread.new { settle_loop }, Thread.new { job_loop }, Thread.new { admin_loop }]
    end

    def running?
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < @deadline
    end

    # The settler waits a moment first, so the first settlement has writes
    # on both sides of it.
    def settle_loop
      sleep(@seconds / 5.0)
      while running?
        @log << [:settler, settle_once, nil]
        sleep(0.3)
      end
    end

    def settle_once
      Rails.application.executor.wrap do
        reconciliation = SettleAndNotify.call(cutoff: @plan.community.yesterday)
        [:settled, reconciliation.id]
      end
    rescue ActiveRecord::RecordInvalid
      :nothing_to_settle
    rescue Settlement::Contested, ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      :conflict
    rescue StandardError => e
      @problems << "settler: #{e.class}: #{e.message}"
      :error
    end

    def job_loop
      while running?
        JOBS.each do |job|
          @log << [:job, run_job(job), job.name]
          sleep(0.2)
        end
      end
    end

    # The way Solid Queue runs a job: through execute, which wraps the
    # perform in the reloader, so Current is fresh for every job.
    def run_job(job)
      ActiveJob::Base.execute(job.new.serialize)
      :ok
    rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      :conflict
    rescue StandardError => e
      @problems << "job #{job.name}: #{e.class}: #{e.message}"
      :error
    end

    def admin_loop
      rng = Random.new(@seed + 1000)
      while running?
        @log << [:admin, admin_write(rng), nil]
        sleep(0.05)
      end
    end

    def admin_write(rng)
      meal = @plan.meals.sample(random: rng)
      resident = @plan.residents.sample(random: rng)
      Rails.application.executor.wrap do
        Current.socket_id = nil
        case rng.rand(3)
        when 0 then MealResident.create!(meal_id: meal.id, resident_id: resident.id)
        when 1 then MealResident.find_by(meal_id: meal.id, resident_id: resident.id)&.destroy!
        else Bill.find_or_initialize_by(meal_id: meal.id, resident_id: resident.id)
                 .update!(amount: BigDecimal(rng.rand(0..9999)) / 100, no_cost: false)
        end
      end
      :ok
    rescue *ADMIN_REFUSALS
      :refused
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.match?(TRIGGER_REFUSAL)

      :refused_by_trigger
    rescue StandardError => e
      @problems << "admin: #{e.class}: #{e.message}"
      :error
    end
  end
end

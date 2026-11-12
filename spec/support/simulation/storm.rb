# frozen_string_literal: true

module Simulation
  # The request storm (Storm::Run) with every actor given to the seeded
  # scheduler instead of a thread of its own: each client, the settler,
  # the nightly jobs and the admin. One SQL statement runs at a time and
  # the seed picks whose, so a storm that fails can be run again step for
  # step (challenge 31).
  #
  # Everything else a run reads is made the same on every run too:
  #   - every table is emptied and its ids start again at 1, so the same
  #     rows get the same ids;
  #   - the data is planted with the seeded clock and generators, and then
  #     ANALYZE runs, so PostgreSQL picks the same plans;
  #   - the cache is a solid_cache store with a fixed namespace, emptied
  #     with the tables;
  #   - the storm's clock is the simulation's clock, so "one second of
  #     storm" is one second of simulated time, whatever the machine.
  class Storm
    Result = Data.define(:steps, :requests, :background, :problems)

    # Tables that hold the schema's own record, not data.
    KEPT_TABLES = %w[schema_migrations ar_internal_metadata].freeze

    def self.call(**)
      new(**).call
    end

    def initialize(seed:, clients:, seconds:, start: Scheduler::START)
      @seed = seed
      @clients = clients
      @seconds = seconds
      @start = start
    end

    def call
      prepare_the_app
      with_a_fresh_cache do
        empty_the_tables
        plan = plant
        run, steps = storm(plan)
        result = run.result
        Result.new(steps: steps, requests: result.requests, background: result.background,
                   problems: problems(result) + checks(plan))
      end
    end

    private

    # Production eager loads; the test environment loads classes and
    # routes on first use, and that load must not happen in the middle of
    # a run, where it would add statements one run has and the next does
    # not (request_storm_spec.rb says more).
    def prepare_the_app
      Rails.application.eager_load!
      Rails.application.reload_routes_unless_loaded
    end

    def with_a_fresh_cache
      store = SolidCache::Store.new(namespace: 'simulation', expiry_method: :job)
      original_cache = Rails.cache
      original_attack_store = Rack::Attack.cache.store
      original_level = Rails.logger.level
      Rails.cache = store
      Rack::Attack.cache.store = store
      Rails.logger.level = Logger::WARN
      yield
    ensure
      Rails.logger.level = original_level
      Rack::Attack.cache.store = original_attack_store
      Rails.cache = original_cache
    end

    def empty_the_tables
      connection = ActiveRecord::Base.connection
      tables = connection.tables - KEPT_TABLES
      connection.execute("TRUNCATE #{tables.map { |t| connection.quote_table_name(t) }.join(', ')} " \
                         'RESTART IDENTITY CASCADE')
    end

    # The planting thread counts as an actor while it plants, so the
    # tokens, ids and times it makes come from the seed.
    def plant
      Determinism.with(seed: @seed, start: @start) do |state|
        state.actor_threads << Thread.current
        plan = ::Storm::Seed.plant(clients: @clients)
        ActiveRecord::Base.connection.execute('ANALYZE')
        plan
      ensure
        state.actor_threads.delete(Thread.current)
      end
    end

    def storm(plan)
      starts_at = @start + 60
      scheduler = Scheduler.new(seed: @seed, start: starts_at)
      run = ::Storm::Run.new(plan: plan, transport: ::Storm::RACK_TRANSPORT, clients: @clients,
                             seconds: @seconds, seed: @seed, clock: -> { Time.now.to_f },
                             starts_at: starts_at.to_f)
      reports = collecting_reports do
        run.actors.each { |name, work| scheduler.actor(name, &work) }
        @steps = scheduler.run.steps
      end
      @reports = reports
      [run, @steps]
    end

    # Everything the app reported through Rails.error and swallowed. Only
    # a conflict may be swallowed (request_storm_spec.rb says why).
    def collecting_reports
      reports = Queue.new
      reporter = Object.new
      reporter.define_singleton_method(:report) { |error, handled:, **| reports << [error, handled] }
      Rails.error.subscribe(reporter)
      yield
      Array.new(reports.size) { reports.pop }
    ensure
      Rails.error.unsubscribe(reporter)
    end

    def problems(result)
      result.requests.filter_map { |e| e.problem && "client #{e.client} ##{e.n} #{e.action}: #{e.problem}" } +
        result.problems +
        @reports.filter_map do |error, handled|
          next if !handled || error.is_a?(ActiveRecord::TransactionRollbackError)

          "reported and swallowed: #{error.class}: #{error.message[0, 300]}"
        end.uniq
    end

    # The checks read the calendar and the community's today, so they run
    # on the simulation's clock too, just after the storm ended.
    def checks(plan)
      Determinism.with(seed: @seed, start: @start + 60 + @seconds + 60) do
        ::Storm::Checks.call(plan: plan, transport: ::Storm::RACK_TRANSPORT)
      end
    end
  end
end

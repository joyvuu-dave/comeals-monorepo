# frozen_string_literal: true

module Simulation
  # What every simulation needs around its scheduler run, so the run
  # starts from the same place each time:
  #   - the app's classes and routes are loaded before the run, as in
  #     production, so no run loads them half way and the next does not;
  #   - every table is emptied and its ids start again at 1, so the same
  #     rows get the same ids;
  #   - the data is planted on the seeded clock and generators, and then
  #     ANALYZE runs, so PostgreSQL picks the same plans;
  #   - the cache is a solid_cache store with a fixed namespace, emptied
  #     with the tables.
  module World
    # Tables that hold the schema's own record, not data.
    KEPT_TABLES = %w[schema_migrations ar_internal_metadata].freeze

    module_function

    # Runs the block with the app ready and a fresh cache in place.
    def around_a_run(&)
      Rails.application.eager_load!
      Rails.application.reload_routes_unless_loaded
      with_a_fresh_cache(&)
    end

    # Empties the tables, then plants (the block) as an actor of a
    # simulation that starts at start, and returns what the block does.
    def plant(seed:, start:)
      empty_the_tables
      Determinism.with(seed: seed, start: start) do |state|
        state.actor_threads << Thread.current
        planted = yield
        ActiveRecord::Base.connection.execute('ANALYZE')
        planted
      ensure
        state.actor_threads.delete(Thread.current)
      end
    end

    def with_a_fresh_cache
      store = SolidCache::Store.new(namespace: 'simulation', expiry_method: :job)
      original_cache = Rails.cache
      original_attack_store = Rack::Attack.cache.store
      original_level = Rails.logger.level
      Rails.cache = store
      Rack::Attack.cache.store = store
      # Thousands of requests: the log lines would be most of the work.
      Rails.logger.level = Logger::WARN
      yield
    ensure
      Rails.logger.level = original_level
      Rack::Attack.cache.store = original_attack_store
      Rails.cache = original_cache
    end

    def empty_the_tables
      connection = ActiveRecord::Base.connection
      tables = (connection.tables - KEPT_TABLES).map { |table| connection.quote_table_name(table) }
      connection.execute("TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE")
    end
  end
end

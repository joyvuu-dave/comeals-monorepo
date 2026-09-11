# frozen_string_literal: true
# typed: false

# Loaded by mutant from .mutant.yml. Three jobs.
#
# 1. Load every class before mutant looks for subjects. The test
#    environment autoloads, so `Settlement*` would match nothing until
#    something had called Settlement.
hooks.register(:env_infection_post) do |env:| # rubocop:disable Lint/UnusedBlockArgument
  Rails.application.eager_load!
end

# 2. Give each worker process its own database. Mutant forks one
#    worker per job, and every worker runs examples inside
#    transactions at SERIALIZABLE. Workers sharing one database would
#    block each other on the unique indexes (two uncommitted rows with
#    the same lower(name)) and abort each other with serialization
#    failures, and an abort counts as a killed mutation. bin/mutant
#    creates comeals_test<suffix>_<index> for every index before the
#    run, copied from the migrated test database.
# The worker's own Postgres session, remembered so hook 3 leaves it alone.
module MutantWorker
  class << self
    attr_accessor :backend_pid
  end
end

hooks.register(:mutation_worker_process_start) do |index:|
  base = ActiveRecord::Base.connection_db_config.configuration_hash
  ActiveRecord::Base.establish_connection(base.merge(database: "#{base[:database]}_#{index}"))
  MutantWorker.backend_pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
end

# 3. Start every mutation from empty tables. The examples in
#    spec/db/settlement_race_spec.rb commit for real (no test transaction)
#    and clean up in their own before and after hooks. A mutation that
#    makes one of them wait forever is killed at the timeout, and a killed
#    process never reaches the after hook, so the rows it committed stay
#    in that worker's database. Every later example in the worker that
#    creates a resident named 'Cook' then fails on the unique name before
#    it checks anything, and mutant counts that as a kill. On 2026-09-10
#    the unmutated code "failed" that way for 13 Settlement methods, so
#    their kills meant nothing. This hook runs in the forked process that
#    tests one mutation, on the worker's own database, before the mutation
#    is inserted. NonTransactionalCleanup is the suite's own TRUNCATE
#    (spec/support, loaded by rails_helper).
#
#    The sessions of killed processes go first. A race example whose
#    rival thread still holds a row lock when the example fails hangs in
#    its own cleanup TRUNCATE, is killed at the timeout, and leaves that
#    lock behind in a session Postgres has not noticed is dead. The next
#    TRUNCATE on the database then waits on it, and the timeouts pile up
#    (89 in one run, 2026-09-10). Every session on this database except
#    the worker's own and this one belongs to a dead process.
#
#    The lock timeout is for the same hang seen from inside one
#    mutation. When a race example fails while its rival thread still
#    holds a row lock, the example's own after-hook TRUNCATE waits on
#    that thread, which never moves again, and the process is only
#    stopped by the mutation timeout: a kill that took 120 seconds
#    instead of 5 (109 of them in one run, 2026-09-11). With the lock
#    timeout the TRUNCATE gives up, the after hook raises, and the
#    process exits with the failure it already reported. This session is
#    the one the examples run on: the fork gets a fresh connection, and
#    every example in the process uses it.
hooks.register(:mutation_insert_pre) do |mutation:| # rubocop:disable Lint/UnusedBlockArgument
  connection = ActiveRecord::Base.connection
  connection.execute(<<~SQL.squish)
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid NOT IN (pg_backend_pid(), #{MutantWorker.backend_pid})
  SQL
  # const_get because Sorbet does not read spec/, where the module lives.
  Object.const_get(:NonTransactionalCleanup).call
  connection.execute("SET lock_timeout = '10s'")
end

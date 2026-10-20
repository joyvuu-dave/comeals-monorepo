# frozen_string_literal: true
# typed: false

# Loaded by mutant from .mutant.yml. Five jobs.
#
# 1. Load every class before mutant looks for subjects. The test
#    environment autoloads, so `Settlement*` would match nothing until
#    something had called Settlement. eager_load! loads only what Rails
#    autoloads. The tables in app/admin/components load when ActiveAdmin
#    loads its pages, and SolidQueueCheck in lib/ is required only by
#    its rake task, so both are loaded here too. Mutant loads the spec
#    files only after it has picked its subjects, so a spec that requires
#    a file does not count. spec/config/mutant_subjects_spec.rb fails
#    when a subject's class is not loaded at this point.
hooks.register(:env_infection_post) do |env:| # rubocop:disable Lint/UnusedBlockArgument
  Rails.application.eager_load!
  ActiveAdmin.application.load!
  Rails.root.glob('lib/**/*.rb').each { |file| require file }
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
    attr_accessor :backend_pid # rubocop:disable ThreadSafety/ClassAndModuleAttributes -- one mutant worker process, one session
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
#
# 4. Limit the memory of the process that tests one mutation
#    (config/mutant/memory_limit.rb says why and how). It is set here,
#    in that process, so it ends only that process.
#
# 5. Turn Thread.abort_on_exception back off in the process that tests
#    one mutation. Mutant sets it to true when it loads
#    (mutant/lib/mutant.rb), for its own threads. With it on, an
#    exception that ends any thread is also raised in the main thread,
#    at whatever line the main thread is on. The race specs in spec/db
#    start threads that are meant to fail, such as a write that the
#    settlement cancels, and read the error later with Thread#value.
#    Under mutant the same error was also raised in the main thread
#    before it reached #value, outside the rescue that expects it, and
#    the unmutated code failed: spec/db/settlement_race_spec.rb's
#    "refused in words when sent again" example in GitHub runs
#    38925071449 and 38946208665. It happened only when the main thread
#    was slow to get from its COMMIT to #value, which is why it was rare.
#    Plain rspec and bin/check leave the setting off, as Ruby does, and
#    the specs are written for that. This hook runs only in the forked
#    process, so mutant's own threads in its main process keep the
#    setting it chose.
require_relative 'memory_limit'

hooks.register(:mutation_insert_pre) do |mutation:| # rubocop:disable Lint/UnusedBlockArgument
  MutantMemoryLimit.apply
  Thread.abort_on_exception = false
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

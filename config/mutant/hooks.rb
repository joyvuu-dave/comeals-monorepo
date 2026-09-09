# frozen_string_literal: true
# typed: false

# Loaded by mutant from .mutant.yml. Two jobs.
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
hooks.register(:mutation_worker_process_start) do |index:|
  base = ActiveRecord::Base.connection_db_config.configuration_hash
  ActiveRecord::Base.establish_connection(base.merge(database: "#{base[:database]}_#{index}"))
end

# frozen_string_literal: true

# Every structure dump (db:migrate, db:prepare, db:schema:dump) leaves
# COMMENT ON EXTENSION out of db/structure.sql: on Heroku only rdsadmin may
# run one, so a new database could not load the file
# (lib/structure_dump_cleanup.rb).
require Rails.root.join('lib/structure_dump_cleanup')

ActiveRecord::Tasks::PostgreSQLDatabaseTasks.prepend(StructureDumpCleanup::AfterDump)

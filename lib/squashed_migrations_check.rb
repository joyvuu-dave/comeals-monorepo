# typed: true
# frozen_string_literal: true

# Refuse to migrate a database that is behind the deleted migrations.
#
# After each deploy that runs migrations, the migrations production ran
# are deleted from db/migrate/, and db/production_schema_version.txt names
# the newest of them (AGENTS.md, "Migrations and db/structure.sql"). A
# database whose newest migration is older than that needs migrations that
# no longer exist as files. db:migrate cannot run them, so it runs nothing
# and succeeds, and the new code runs on a database without the tables it
# needs. That happened on staging on 2026-10-24: its database had been
# restored from an older backup, the deploy passed every step, and then
# BrowserReportJob failed with `relation "browser_counts" does not exist`.
# The same would happen on production after the Rollback workflow restores
# a backup from before a deploy, if main is then deployed again.
#
# So the release phase runs `deploy:verify_schema_version` before
# db:migrate (Procfile). Every way of deploying (bin/deploy, the Deploy
# workflow, a plain git push) runs the release phase, and Heroku does not
# promote a release whose release phase fails. bin/deploy asks the same
# question earlier, with heroku pg:psql, so it stops before the backup and
# before maintenance goes on.
#
# A database that has run no migration at all is new, and passes: its
# schema comes from db/structure.sql, not from migrations, and db:migrate
# makes schema_migrations as it always has.
module SquashedMigrationsCheck
  extend T::Sig

  VERSION_FILE = 'db/production_schema_version.txt'

  class DatabaseBehind < StandardError; end

  # The one version the file names. Lines that start with # and blank
  # lines are skipped, the same way spec/simplecov_profile.rb reads it.
  sig { params(text: String).returns(Integer) }
  def self.squashed_version(text)
    versions = text.lines(chomp: true).reject { |line| line.start_with?('#') || line.blank? }
    raise ArgumentError, "#{VERSION_FILE} must hold one version, not #{versions}" unless versions.size == 1

    Integer(versions.first, 10)
  end

  # The newest version in schema_migrations, as a number. nil when the
  # table does not exist or has no rows: the database has run no
  # migration.
  sig { returns(T.nilable(Integer)) }
  def self.newest_version
    schema_migration = ActiveRecord::Base.connection_pool.schema_migration
    return nil unless schema_migration.table_exists?

    schema_migration.integer_versions.max
  end

  # A sentence that says what is wrong and what to do, or nil when the
  # database is not behind.
  sig { params(newest: T.nilable(Integer), squashed: Integer).returns(T.nilable(String)) }
  def self.problem(newest:, squashed:)
    return nil if newest.nil? || newest >= squashed

    "The database is behind #{VERSION_FILE}. Its newest migration is #{newest}, but the file says #{squashed}: " \
      "the migrations up to #{squashed} were deleted from db/migrate/ after production ran them. db:migrate " \
      'cannot run a migration that has no file, so this code would run on a database without the tables and ' \
      'columns those migrations made. Do one of these: restore a backup taken after production ran migration ' \
      "#{squashed}, or deploy a commit whose #{VERSION_FILE} is #{newest} or older (that commit still has the " \
      'migration files).'
  end

  # Raises DatabaseBehind when the database is behind the file. Returns
  # the newest version in the database, nil for a new database.
  sig { returns(T.nilable(Integer)) }
  def self.verify!
    newest = newest_version
    reason = problem(newest:, squashed: squashed_version(Rails.root.join(VERSION_FILE).read))
    raise DatabaseBehind, reason if reason

    newest
  end
end

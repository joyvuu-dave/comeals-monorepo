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
# The check compares every migration db/structure.sql lists up to that
# version with schema_migrations, not only the newest: a database can be
# new enough and still be missing an older one.
#
# So the release phase runs `deploy:verify_schema_version` before
# db:migrate (Procfile). Every way of deploying (bin/deploy, the Deploy
# workflow, a plain git push) runs the release phase, and Heroku does not
# promote a release whose release phase fails. bin/deploy asks the same
# question earlier, and bin/lib/rollback/check-backup asks it of a backup
# before the restore. Both use this rule through bin/lib/schema-check, so
# all three refuse the same databases in the same words.
#
# A database with no tables at all is new, and passes: db:migrate loads
# db/structure.sql into it before it migrates (Rails 8.1 does this when
# there is no schema_migrations table), and the file's last statement
# fills schema_migrations. A database with tables but no versions is
# refused (see .problem).
module SquashedMigrationsCheck
  extend T::Sig

  VERSION_FILE = 'db/production_schema_version.txt'
  STRUCTURE_FILE = 'db/structure.sql'

  class DatabaseBehind < StandardError; end

  # The one version the file names. Lines that start with # and blank
  # lines are skipped, the same way spec/simplecov_profile.rb reads it.
  sig { params(text: String).returns(Integer) }
  def self.squashed_version(text)
    versions = text.lines(chomp: true).reject { |line| line.start_with?('#') || line.strip.empty? }
    raise ArgumentError, "#{VERSION_FILE} must hold one version, not #{versions}" unless versions.size == 1

    Integer(versions.first, 10)
  end

  # The versions db/structure.sql records as run: its INSERT INTO
  # schema_migrations list. A new database starts with these rows. The
  # ones up to the version in VERSION_FILE are the migrations whose files
  # were deleted.
  sig { params(text: String).returns(T::Array[Integer]) }
  def self.recorded_versions(text)
    list = text[/^INSERT INTO "schema_migrations" \(version\) VALUES\n(.*?);$/m, 1]
    raise ArgumentError, "#{STRUCTURE_FILE} has no INSERT INTO schema_migrations list" if list.nil?

    list.scan(/'(\d+)'/).flatten.map { Integer(it, 10) }
  end

  # The versions in schema_migrations, as numbers. Empty when the table
  # does not exist or has no rows: the database has run no migration.
  sig { returns(T::Array[Integer]) }
  def self.database_versions
    schema_migration = ActiveRecord::Base.connection_pool.schema_migration
    return [] unless schema_migration.table_exists?

    schema_migration.integer_versions
  end

  # A sentence that says what is wrong and what to do, or nil when the
  # database has run every deleted migration, or is new. `database` holds
  # the versions in schema_migrations, `recorded` the versions in
  # db/structure.sql, `squashed` the version in VERSION_FILE, and `tables`
  # the tables in the database.
  #
  # Every deleted migration is compared, not only the newest: a database
  # whose newest migration is new enough can still be missing an older one
  # (#248, item 3).
  #
  # A new database has no tables and no versions. One with tables but no
  # versions is refused: with no schema_migrations table, db:migrate loads
  # db/structure.sql over the tables that are there, and makes every
  # object the file lists before the first one that already exists; with
  # an empty schema_migrations table (a load that stopped part way), it
  # loads nothing and runs nothing.
  sig do
    params(database: T::Array[Integer], squashed: Integer, recorded: T::Array[Integer],
           tables: T::Array[String]).returns(T.nilable(String))
  end
  def self.problem(database:, squashed:, recorded:, tables:)
    newest = database.max
    return (tables.empty? ? nil : not_new(tables)) if newest.nil?
    return behind(newest:, squashed:) if newest < squashed

    missing = (recorded.select { it <= squashed } - database).sort
    return nil if missing.empty?

    gap(missing:, squashed:)
  end

  sig { params(tables: T::Array[String]).returns(String) }
  def self.not_new(tables)
    "The database has tables (#{first_few(tables.sort)}) but no record of the migrations it has run: " \
      'schema_migrations is missing or has no rows. So it is not a new database. With no schema_migrations ' \
      "table, db:migrate would load #{STRUCTURE_FILE} over these tables, and with an empty one it would do " \
      'nothing, so this code would run on a database it does not fit. Do one of these: restore a backup of ' \
      'this database, or, if this is a new app with no data to keep, empty its database (heroku pg:reset) ' \
      'and deploy again.'
  end

  # At most this many tables or versions are named, so the message stays
  # short enough to read in the release output.
  NAMED = 10

  sig { params(items: T::Array[T.any(Integer, String)]).returns(String) }
  def self.first_few(items)
    named = items.first(NAMED).join(', ')
    items.size > NAMED ? "#{named} and #{items.size - NAMED} more" : named
  end

  sig { params(newest: Integer, squashed: Integer).returns(String) }
  def self.behind(newest:, squashed:)
    "The database is behind #{VERSION_FILE}. Its newest migration is #{newest}, but the file says #{squashed}: " \
      "the migrations up to #{squashed} were deleted from db/migrate/ after production ran them. db:migrate " \
      'cannot run a migration that has no file, so this code would run on a database without the tables and ' \
      'columns those migrations made. Do one of these: restore a backup taken after production ran migration ' \
      "#{squashed}, or deploy a commit whose #{VERSION_FILE} is #{newest} or older (that commit still has the " \
      'migration files).'
  end

  sig { params(missing: T::Array[Integer], squashed: Integer).returns(String) }
  def self.gap(missing:, squashed:)
    "The database has not run #{missing.size} of the migrations that were deleted from db/migrate/ after " \
      "production ran them: #{first_few(missing)}. Its newest migration is not older than #{VERSION_FILE} " \
      "(#{squashed}), " \
      "but #{STRUCTURE_FILE} lists these as run, and they are not in schema_migrations. db:migrate cannot run " \
      'a migration that has no file, so this code would run on a database without the tables and columns ' \
      'those migrations made. Do one of these: restore a backup taken after production ran migration ' \
      "#{squashed}, or deploy a commit whose #{VERSION_FILE} is older than #{missing.first} (that commit " \
      'still has the migration files).'
  end

  # Raises DatabaseBehind when the database is missing a deleted
  # migration, or has tables but no versions. Returns the newest version
  # in the database, nil for a new database.
  sig { returns(T.nilable(Integer)) }
  def self.verify!
    database = database_versions
    reason = problem(database:,
                     squashed: squashed_version(Rails.root.join(VERSION_FILE).read),
                     recorded: recorded_versions(Rails.root.join(STRUCTURE_FILE).read),
                     tables: ActiveRecord::Base.connection.tables)
    raise DatabaseBehind, reason if reason

    database.max
  end
end

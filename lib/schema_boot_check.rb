# typed: true
# frozen_string_literal: true

require_relative 'squashed_migrations_check'

# Refuse to start web or the worker on a database the code does not fit.
#
# The release phase checks the database before every deploy
# (deploy:verify_schema_version, lib/squashed_migrations_check.rb). A
# restore with no deploy after it runs no release phase: a
# `heroku pg:backups:restore` by hand, or the Rollback workflow when its
# restore works and its code rollback fails. Then nothing compares the
# restored database with the code, and the code runs on tables it does
# not fit (#248). So web (config.ru) and the worker (bin/jobs) run this
# when they start. A process that refuses to start crashes, and Heroku
# shows the reason in the logs.
#
# It refuses two kinds of database:
#
#   - one that is missing a migration whose file was deleted, or that has
#     tables but no versions (SquashedMigrationsCheck has the rule; this
#     does not repeat it);
#   - one that has not run a migration that is still in db/migrate/: a
#     backup from before the last deploy, restored onto that deploy's
#     code.
#
# It also refuses a database with no tables. The release check lets that
# one through, because db:migrate builds it; here nothing would, and web
# would fail on every request.
#
# Only web and the worker run it, not an initializer, so every other
# process still starts: the release phase, whose db:migrate runs before
# web starts and so must run on a database that has not run the new
# migrations yet, and a one-off dyno (heroku run: a console, a rake task),
# which is where a person looks at a wrong database and repairs it. It
# runs in every environment, so bin/dev and the browser suites start the
# same way as production.
module SchemaBootCheck
  extend T::Sig

  class DatabaseBehind < StandardError; end

  NO_TABLES = 'The database has no tables. On a laptop, run bin/rails db:prepare. On Heroku, deploy: the ' \
              'release phase builds the tables from db/structure.sql.'

  # `process` names the process in the message, like "The web process".
  sig { params(process: String).void }
  def self.verify!(process)
    begin
      newest = SquashedMigrationsCheck.verify!
    rescue SquashedMigrationsCheck::DatabaseBehind => e
      raise DatabaseBehind, refusal(process, e.message)
    end
    raise DatabaseBehind, refusal(process, NO_TABLES) if newest.nil?

    pending = pending_versions(ActiveRecord::Base.connection_pool.migration_context)
    return if pending.empty?

    raise DatabaseBehind, refusal(process, pending_problem(pending))
  end

  # The versions of the migration files the database has not run, read
  # from the file names. Not MigrationContext#pending_migration_versions:
  # it refuses a file dated after "now", and the integration and admin
  # browser suites start web with the clock stopped at a day in the past
  # (config/initializers/integration_fake_time.rb).
  sig { params(context: ActiveRecord::MigrationContext).returns(T::Array[Integer]) }
  def self.pending_versions(context)
    files = Array(context.migrations_paths).flat_map { Dir[File.join(it, '**', '[0-9]*_*.rb')] }
    versions = files.map { Integer(File.basename(it)[/\A\d+/], 10) }
    (versions - context.schema_migration.integer_versions).sort
  end

  sig { params(pending: T::Array[Integer]).returns(String) }
  def self.pending_problem(pending)
    count = pending.size == 1 ? '1 migration that is' : "#{pending.size} migrations that are"
    "The database has not run #{count} in db/migrate/: #{pending.join(', ')}. Run " \
      'bin/rake db:migrate (on Heroku: heroku run bin/rake db:migrate, or deploy again, which runs it in the ' \
      'release phase).'
  end

  sig { params(process: String, reason: String).returns(String) }
  def self.refusal(process, reason)
    "#{process} will not start. #{reason} heroku run (a console or a rake task) still starts, so the " \
      'database can be looked at and repaired there. (lib/schema_boot_check.rb)'
  end
end

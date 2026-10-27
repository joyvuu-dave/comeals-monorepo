# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/schema_boot_check')

# The check web and the worker run when they start (config.ru, bin/jobs).
# A restore by hand runs no release phase, so the release check never sees
# the restored database. This check sees it when the next web or worker
# process starts, and refuses to start on a database that the code does
# not fit (#248).
RSpec.describe SchemaBootCheck do
  let(:connection) { ActiveRecord::Base.connection }

  it 'passes on a database that has run every migration' do
    expect { described_class.verify!('The web process') }.not_to raise_error
  end

  it 'refuses a database that is behind the deleted migrations, and says what still works' do
    connection.execute("DELETE FROM schema_migrations WHERE version::bigint >= #{PRODUCTION_SCHEMA_VERSION}")
    reason = SquashedMigrationsCheck.problem(
      database: SquashedMigrationsCheck.database_versions, squashed: PRODUCTION_SCHEMA_VERSION,
      recorded: SquashedMigrationsCheck.recorded_versions(Rails.root.join('db/structure.sql').read),
      tables: connection.tables
    )

    expect { described_class.verify!('The web process') }.to raise_error(
      described_class::DatabaseBehind,
      "The web process will not start. #{reason} heroku run (a console or a rake task) still starts, " \
      'so the database can be looked at and repaired there. (lib/schema_boot_check.rb)'
    )
  end

  # A restore of a backup from before the last deploy, onto that deploy's
  # code: the deploy's own migrations still have their files, so the
  # database is not behind the deleted ones, but it has not run these.
  describe 'a migration file the database has not run' do
    include ActiveSupport::Testing::TimeHelpers

    let(:dir) { Dir.mktmpdir('migrations') }
    let(:pool) { ActiveRecord::Base.connection_pool }

    before do
      File.write(File.join(dir, "#{PRODUCTION_SCHEMA_VERSION + 1}_a_later_change.rb"),
                 "class ALaterChange < ActiveRecord::Migration[8.1]; end\n")
      context = ActiveRecord::MigrationContext.new(dir, pool.schema_migration, pool.internal_metadata)
      allow(pool).to receive(:migration_context).and_return(context)
    end

    after { FileUtils.remove_entry(dir) }

    it 'refuses to start, names the migration and says how to run it' do
      expect { described_class.verify!('The jobs process') }.to raise_error(
        described_class::DatabaseBehind,
        'The jobs process will not start. The database has not run 1 migration that is in db/migrate/: ' \
        "#{PRODUCTION_SCHEMA_VERSION + 1}. Run bin/rake db:migrate (on Heroku: heroku run bin/rake " \
        'db:migrate, or ' \
        'deploy again, which runs it in the release phase). heroku run (a console or a rake task) still ' \
        'starts, so the database can be looked at and repaired there. (lib/schema_boot_check.rb)'
      )
    end

    it 'counts two or more migrations' do
      File.write(File.join(dir, "#{PRODUCTION_SCHEMA_VERSION + 2}_another_change.rb"),
                 "class AnotherChange < ActiveRecord::Migration[8.1]; end\n")

      versions = "#{PRODUCTION_SCHEMA_VERSION + 1}, #{PRODUCTION_SCHEMA_VERSION + 2}"

      expect { described_class.verify!('The web process') }.to raise_error(
        described_class::DatabaseBehind, %r{has not run 2 migrations that are in db/migrate/: #{versions}\.}
      )
    end

    # Rails takes more than one migrations folder (config.paths['db/migrate']).
    it 'reads the files of every migrations folder' do
      other = Dir.mktmpdir('more_migrations')
      File.write(File.join(other, "#{PRODUCTION_SCHEMA_VERSION + 2}_in_another_folder.rb"),
                 "class InAnotherFolder < ActiveRecord::Migration[8.1]; end\n")
      context = ActiveRecord::MigrationContext.new([dir, other], pool.schema_migration, pool.internal_metadata)
      allow(pool).to receive(:migration_context).and_return(context)

      versions = "#{PRODUCTION_SCHEMA_VERSION + 1}, #{PRODUCTION_SCHEMA_VERSION + 2}"
      expect { described_class.verify!('The web process') }.to raise_error(
        described_class::DatabaseBehind, %r{has not run 2 migrations that are in db/migrate/: #{versions}\.}
      )
    ensure
      FileUtils.remove_entry(other)
    end

    # The integration and admin browser suites start web with the clock
    # stopped at a day in the past (config/initializers/integration_fake_time.rb).
    # Rails refuses to read a migration file dated after "now", so reading
    # the files through Rails would stop web from starting at all whenever
    # db/migrate/ holds a migration newer than that day.
    it 'reads the migration files when the clock is stopped before their date' do
      travel_to(Time.zone.local(2026, 1, 15, 12)) do
        expect { described_class.verify!('The web process') }
          .to raise_error(described_class::DatabaseBehind, /has not run 1 migration/)
      end
    end
  end

  it 'refuses a database that has tables but has run no migration' do
    connection.execute('DELETE FROM schema_migrations')

    expect { described_class.verify!('The web process') }
      .to raise_error(described_class::DatabaseBehind, /\AThe web process will not start. The database has tables/)
  end

  # A database with no tables, which nothing has built yet. Web would
  # start and then fail on every request.
  it 'refuses a database with no tables, and says how to build it' do
    allow(SquashedMigrationsCheck).to receive(:database_versions).and_return([])
    allow(connection).to receive(:tables).and_return([])

    expect { described_class.verify!('The web process') }.to raise_error(
      described_class::DatabaseBehind,
      'The web process will not start. The database has no tables. On a laptop, run bin/rails db:prepare. On ' \
      'Heroku, deploy: the release phase builds the tables from db/structure.sql. heroku run (a console or a ' \
      'rake task) still starts, so the database can be looked at and repaired there. (lib/schema_boot_check.rb)'
    )
  end
end

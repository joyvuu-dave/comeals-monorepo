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
    newest = SquashedMigrationsCheck.newest_version
    reason = SquashedMigrationsCheck.problem(newest:, squashed: PRODUCTION_SCHEMA_VERSION)

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
    let(:dir) { Dir.mktmpdir('migrations') }
    let(:pool) { ActiveRecord::Base.connection_pool }

    before do
      File.write(File.join(dir, '20991231000000_a_later_change.rb'),
                 "class ALaterChange < ActiveRecord::Migration[8.1]; end\n")
      context = ActiveRecord::MigrationContext.new(dir, pool.schema_migration, pool.internal_metadata)
      allow(pool).to receive(:migration_context).and_return(context)
    end

    after { FileUtils.remove_entry(dir) }

    it 'refuses to start, names the migration and says how to run it' do
      expect { described_class.verify!('The jobs process') }.to raise_error(
        described_class::DatabaseBehind,
        'The jobs process will not start. The database has not run 1 migration that is in db/migrate/: ' \
        '20991231000000. Run it with bin/rake db:migrate (on Heroku: heroku run bin/rake db:migrate, or ' \
        'deploy again, which runs it in the release phase). heroku run (a console or a rake task) still ' \
        'starts, so the database can be looked at and repaired there. (lib/schema_boot_check.rb)'
      )
    end
  end

  # A brand new app's database has run no migration. The release check
  # lets it through too.
  it 'passes a database that has run no migration' do
    connection.execute('DELETE FROM schema_migrations')

    expect { described_class.verify!('The web process') }.not_to raise_error
  end
end

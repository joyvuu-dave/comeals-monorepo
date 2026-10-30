# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The task is thin: bin/deploy, the weekly workflow and the staging
# rehearsal run it after a deploy. It raises through SolidQueueCheck,
# which is what makes the rake process exit non-zero and the deploy stop.
RSpec.describe 'deploy:verify_solid_queue' do
  before(:all) { RakeTasks.ensure_loaded }

  after { Rake::Task['deploy:verify_solid_queue'].reenable }

  it 'verify_solid_queue raises when no process has a heartbeat' do
    expect { Rake::Task['deploy:verify_solid_queue'].invoke }.to raise_error(/Solid Queue is not fully running/)
  end

  it 'verify_solid_queue passes and names the kinds when every one is alive' do
    SolidQueueCheck::PROCESS_KINDS.each do |kind|
      SolidQueue::Process.create!(kind: kind, last_heartbeat_at: Time.current, pid: 1, name: "#{kind}-1")
    end

    expect { Rake::Task['deploy:verify_solid_queue'].invoke }
      .to output(/Supervisor, Dispatcher, Worker, Scheduler are running/).to_stdout
  end

  describe 'deploy:verify_recurring_job' do
    after { Rake::Task['deploy:verify_recurring_job'].reenable }

    it 'raises when the scheduler has saved no task' do
      expect { Rake::Task['deploy:verify_recurring_job'].invoke }
        .to raise_error(/the scheduler has not saved its tasks/)
    end
  end

  # The release phase runs it before db:migrate (Procfile). It raises
  # through SquashedMigrationsCheck, which makes the rake process exit
  # non-zero, so Heroku does not promote the release.
  describe 'deploy:verify_schema_version' do
    after { Rake::Task['deploy:verify_schema_version'].reenable }

    # The newest version db/structure.sql lists, not PRODUCTION_SCHEMA_VERSION:
    # a branch that adds a migration lists a newer one (#261).
    it 'passes and names the newest version when the database has run every deleted migration' do
      newest = SquashedMigrationsCheck.recorded_versions(Rails.root.join('db/structure.sql').read).max

      expect { Rake::Task['deploy:verify_schema_version'].invoke }
        .to output('deploy:verify_schema_version: the database has run every deleted migration, the ones ' \
                   'db/structure.sql lists up to db/production_schema_version.txt. Its newest migration is ' \
                   "#{newest}.\n").to_stdout
    end

    it 'raises when the database is behind db/production_schema_version.txt' do
      ActiveRecord::Base.connection.execute(
        "DELETE FROM schema_migrations WHERE version::bigint >= #{PRODUCTION_SCHEMA_VERSION}"
      )

      expect { Rake::Task['deploy:verify_schema_version'].invoke }
        .to raise_error(SquashedMigrationsCheck::DatabaseBehind, /The database is behind/)
    end

    # The test database has every table, so the new database is made up
    # here: no versions and no tables.
    it 'passes and says so on a new database, which has no tables' do
      allow(SquashedMigrationsCheck).to receive(:database_versions).and_return([])
      allow(ActiveRecord::Base.connection).to receive(:tables).and_return([])

      expect { Rake::Task['deploy:verify_schema_version'].invoke }
        .to output('deploy:verify_schema_version: the database has no tables, so it is new. ' \
                   "db:migrate builds it from db/structure.sql.\n").to_stdout
    end

    it 'raises when the database has tables but no versions' do
      ActiveRecord::Base.connection.execute('DELETE FROM schema_migrations')

      expect { Rake::Task['deploy:verify_schema_version'].invoke }
        .to raise_error(SquashedMigrationsCheck::DatabaseBehind, /but no record of the migrations it has run/)
    end
  end
end

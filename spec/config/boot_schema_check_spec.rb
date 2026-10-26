# frozen_string_literal: true

require 'rails_helper'

# Which processes run SchemaBootCheck when they start, run for real on a
# database of their own (#248):
#
#   - web (config.ru, which Puma loads) and the worker (bin/jobs) refuse to
#     start on a database the code does not fit. They serve people and
#     run the jobs, so they must not run on the wrong tables.
#   - a one-off process (heroku run: a console, a rake task, a runner)
#     still starts. The release phase is one: its db:migrate runs before
#     web starts, so it must run on a database that has not run the new
#     migrations yet. And a console is what a person uses to look at a
#     database that is wrong, and to repair it.
RSpec.describe 'the schema check at boot' do
  include ThrowawayDatabase

  before { create_throwaway_database }
  after { drop_throwaway_database }

  # A database restored from a backup taken before the deleted migrations.
  def make_the_database_behind
    on_database(throwaway_database, 'CREATE TABLE schema_migrations (version varchar PRIMARY KEY)',
                "INSERT INTO schema_migrations VALUES ('#{PRODUCTION_SCHEMA_VERSION - 1}')")
  end

  # The way Puma reads config.ru.
  def load_config_ru
    run_on_throwaway_database('bundle', 'exec', 'ruby', '-e', "require 'rack'; Rack::Builder.parse_file('config.ru')")
  end

  # Runs bin/jobs and stops it after `seconds` if it is still running. A
  # bin/jobs that starts runs until it is stopped.
  def run_jobs(seconds: 60)
    env = { 'RAILS_ENV' => 'test', 'RUBYOPT' => nil, 'DATABASE_URL' => throwaway_url }
    Open3.popen2e(env, 'bin/jobs', '--mode', 'async', chdir: Rails.root.to_s) do |stdin, out, waiter|
      stdin.close
      reader = Thread.new { out.read }
      unless waiter.join(seconds)
        Process.kill('TERM', waiter.pid)
        waiter.join
      end
      [reader.value, waiter.value]
    end
  end

  describe 'on a database that is behind the deleted migrations' do
    before { make_the_database_behind }

    it 'refuses to load config.ru, so Puma does not start' do
      output, status = load_config_ru

      expect(status).not_to be_success
      expect(output).to include('The web process will not start. The database is behind ' \
                                'db/production_schema_version.txt.')
    end

    it 'refuses to start the jobs process' do
      output, status = run_jobs

      expect(status.exited?).to be(true), "bin/jobs was still running after 60 seconds:\n#{output}"
      expect(status).not_to be_success
      expect(output).to include('The jobs process will not start. The database is behind ' \
                                'db/production_schema_version.txt.')
    end

    it 'still starts a one-off process, such as a console or a runner' do
      output, status = run_on_throwaway_database('bin/rails', 'runner', 'print :started')

      expect(status).to be_success, output
      expect(output.lines.last).to eq('started')
    end
  end

  # A brand new app's database, before its first release. The release
  # check lets it through too.
  describe 'on a database with no tables' do
    it 'loads config.ru' do
      output, status = load_config_ru

      expect(status).to be_success, output
    end
  end

  describe 'on a database that has run every migration' do
    before do
      _output, status = Open3.capture2e('psql', '--quiet', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
                                        '--output', File::NULL, '--file', 'db/structure.sql', throwaway_url,
                                        chdir: Rails.root.to_s)
      raise 'could not load db/structure.sql' unless status.success?
    end

    it 'loads config.ru' do
      output, status = load_config_ru

      expect(status).to be_success, output
    end
  end
end

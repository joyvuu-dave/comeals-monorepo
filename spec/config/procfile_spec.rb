# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# Heroku runs one dyno per process type in the Procfile. The web dyno runs
# Puma only. The jobs run on a dyno of their own, the worker, which runs
# bin/jobs: Solid Queue's supervisor, in async mode, with config/queue.yml
# (spec/config/initializers/solid_queue_spec.rb). The release phase
# checks that the database is not behind db/production_schema_version.txt
# (lib/squashed_migrations_check.rb), then migrates.
#
# Async mode runs the dispatcher, the worker and the scheduler as threads
# of the supervisor's one process, instead of three forked processes. One
# Rails process on the dyno uses less memory than four, and one pool
# holds every connection the jobs use.
RSpec.describe 'Procfile' do
  let(:processes) do
    Rails.root.join('Procfile').readlines(chomp: true).reject(&:empty?)
         .to_h { |line| line.split(/:\s*/, 2) }
  end

  # The pool the worker line gives its process, from `env RAILS_DB_POOL=N`.
  let(:worker_pool) { Integer(processes.fetch('worker')[/\Aenv RAILS_DB_POOL=(\d+) /, 1], 10) }

  let(:configuration) { SolidQueue::Configuration.new(mode: :async) }

  it 'has a web, a worker and a release process, and nothing else' do
    expect(processes).to eq(
      'web' => 'bundle exec puma -C config/puma.rb',
      'worker' => 'env RAILS_DB_POOL=12 bin/jobs --mode async',
      'release' => 'bin/rake deploy:verify_schema_version db:migrate'
    )
  end

  # The release command, run for real on a database of its own. Rake runs
  # the tasks in the order the line names them and stops at the first that
  # fails, so a database that is behind is never migrated, and Heroku does
  # not promote the release.
  describe 'the release command' do
    include ThrowawayDatabase

    let(:dump_dir) { Dir.mktmpdir('release-dump') }

    # SCHEMA sends the schema dump that db:migrate writes in the test
    # environment to a folder of its own, so db/structure.sql is never
    # touched.
    def run_release
      run_on_throwaway_database(*processes.fetch('release').split,
                                env: { 'SCHEMA' => File.join(dump_dir, 'structure.sql') })
    end

    before { create_throwaway_database }

    after do
      drop_throwaway_database
      FileUtils.remove_entry(dump_dir)
    end

    it 'refuses, and migrates nothing, when the database is behind the deleted migrations' do
      on_database(throwaway_database, 'CREATE TABLE schema_migrations (version varchar PRIMARY KEY)',
                  "INSERT INTO schema_migrations VALUES ('#{PRODUCTION_SCHEMA_VERSION - 1}')")

      output, status = run_release

      expect(status).not_to be_success
      expect(output).to include('The database is behind db/production_schema_version.txt. ' \
                                "Its newest migration is #{PRODUCTION_SCHEMA_VERSION - 1}")
      # db:migrate makes ar_internal_metadata. It did not run.
      expect(throwaway_tables).to eq(['schema_migrations'])
    end

    # Its newest migration is the one the file names, but it has not run
    # the ones before it (#248, item 3).
    it 'refuses, and migrates nothing, when the database is missing an older deleted migration' do
      on_database(throwaway_database, 'CREATE TABLE schema_migrations (version varchar PRIMARY KEY)',
                  "INSERT INTO schema_migrations VALUES ('#{PRODUCTION_SCHEMA_VERSION}')")

      output, status = run_release

      expect(status).not_to be_success, output
      expect(output).to include('The database has not run')
      expect(throwaway_tables).to eq(['schema_migrations'])
    end

    # A brand new app's database. db:migrate makes the two tables Rails
    # keeps, as it did before the check. The app's own tables come from
    # db/structure.sql.
    it 'migrates an empty database the way it did before the check' do
      output, status = run_release

      expect(status).to be_success, output
      expect(throwaway_tables).to eq(%w[ar_internal_metadata schema_migrations])
    end
  end

  # In async mode every thread of every Solid Queue process shares one
  # pool. Solid Queue's own estimate (a connection per worker thread, plus
  # the worker's poll and heartbeat) counts the worker alone, so this
  # counts each thread that can hold a connection at the same moment, from
  # the gem's 1.7.0 code:
  #
  #   - the supervisor: its own thread (it boots, and releases the jobs of
  #     a thread that died), its heartbeat, and its maintenance timer
  #     (prune) — 3;
  #   - each dispatcher: its poll, its heartbeat, and its maintenance timer
  #     (semaphores, blocked jobs, batches) — 3;
  #   - each worker: one per thread that runs jobs, its poll and its
  #     heartbeat — threads + 2;
  #   - the scheduler: its heartbeat, and one for each recurring task that
  #     can come due at the same moment as others (its own thread reads
  #     nothing while dynamic tasks are off) — 1 + that number;
  #   - solid_cache's trim thread, as in every process — 1.
  #
  # So `threads: 3` in config/queue.yml, or two recurring tasks at the same
  # minute, without a larger pool here fails this example instead of
  # starting with too few connections.
  it 'gives the jobs process a connection for every thread that can use one at the same moment' do
    expect(configuration.mode).to be_async
    kinds = configuration.configured_processes.map(&:kind)
    workers = configuration.configured_processes.select { |process| process.kind == :worker }
    tasks_at_once = most_recurring_tasks_due_at_once(configuration.send(:recurring_tasks))

    needed = 3 +
             (3 * kinds.count(:dispatcher)) +
             workers.sum { |worker| worker.attributes.fetch(:threads) + 2 } +
             (kinds.include?(:scheduler) ? 1 + tasks_at_once : 0) +
             1

    expect(needed).to eq(12)
    expect(worker_pool).to be >= needed
  end

  it 'starts Solid Queue in async mode' do
    command = processes.fetch('worker').split
    options = SolidQueue::Cli.new([], command.drop(command.index('bin/jobs') + 1)).options

    expect(options[:mode]).to eq('async')
  end

  # Heroku's own Procfile example sets a variable with `env QUEUE=*
  # bundle exec rake resque:work`, and env works whether or not a shell
  # reads the line. This runs the worker line the same way, with a probe
  # in place of bin/jobs, and asks the booted app for its pool.
  it 'starts the jobs process with that pool' do
    command = processes.fetch('worker').split(' bin/jobs').first.split +
              ['bin/rails', 'runner', 'print ActiveRecord::Base.connection_db_config.max_connections']
    output, status = Open3.capture2e({ 'RAILS_ENV' => 'test', 'RUBYOPT' => nil, 'RAILS_DB_POOL' => '9' },
                                     *command, chdir: Rails.root.to_s)

    expect(status).to be_success, output
    expect(output.lines.last).to eq(worker_pool.to_s)
  end

  # The most recurring tasks that come due in the same minute, over two
  # days from now (every schedule in config/recurring.yml repeats daily or
  # more often).
  def most_recurring_tasks_due_at_once(tasks)
    stop = 2.days.from_now
    due = Hash.new(0)
    tasks.each do |task|
      time = task.next_time
      while time < stop
        due[time.utc.change(sec: 0)] += 1
        time = task.next_time_after(time)
      end
    end
    due.values.max
  end
end

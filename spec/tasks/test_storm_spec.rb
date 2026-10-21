# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'net/http'

# bin/storm boots a Puma and then runs test:storm, which hits that server
# over TCP. Here there is no server: Net::HTTP.start hands the task an
# object that sends each request through the app in this process, the way
# spec/concurrency/request_storm_spec.rb does. Everything else is the
# task's own: it plants the rows, runs the clients, the settler, the jobs
# and the admin, checks the books, and prints the round-trip times. The
# storm is short and small, because what is tested here is the task, not
# the app under load (the in-process storm and bin/storm do that).
#
# The task commits from many threads, so this group runs with no test
# transaction. prosopite: false for the reason in recycled_thread_spec.rb.
RSpec.describe 'test:storm', prosopite: false, type: :task do
  include_context 'with no test transaction'

  # A stand-in for a Net::HTTP connection to the server bin/storm starts.
  # It answers through Rails.application, from the loopback address, the
  # way Puma would hand the request on.
  let(:http_class) do
    Class.new do
      attr_reader :finished

      def request(request)
        env = Rack::MockRequest.env_for(request.path, method: request.method, input: request.body.to_s,
                                                      'CONTENT_TYPE' => request['Content-Type'],
                                                      'REMOTE_ADDR' => '127.0.0.1')
        request.each_header { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
        status, headers, body = Rails.application.call(env)
        text = +''
        body.each { |chunk| text << chunk }
        body.close if body.respond_to?(:close)
        # Net::HTTP asks for gzip and unpacks the answer itself.
        text = Zlib.gunzip(text) if headers['content-encoding'] == 'gzip'
        Struct.new(:code, :body).new(status.to_s, text)
      end

      def finish
        @finished = true
      end
    end
  end

  let(:task) { Rake::Task['test:storm'] }
  let(:connections) { [] }
  # Starts as an empty history, the way the file starts on a first run.
  let(:latency_file) { Tempfile.new(['storm_latency', '.json']).tap { |file| file.write('{}') && file.close } }
  # What bin/storm would set, for a short, small storm.
  let(:storm_env) do
    { 'STORM_URL' => 'http://storm.test:3001', 'STORM_SECONDS' => '2', 'STORM_CLIENTS' => '2', 'STORM_SEED' => '1',
      'STORM_MAX_P95' => nil, 'STORM_SOLID_QUEUE' => nil, 'STORM_JOBS_PROCESSES' => nil, 'STORM_SQ_DRAIN' => nil,
      'STORM_ERROR_LOG' => nil }
  end
  # What the task printed, kept when it stops with abort too.
  let(:printed) { StringIO.new }

  before(:all) do
    RakeTasks.ensure_loaded
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @original_db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    # The reason is in request_storm_spec.rb: the test environment loads
    # classes and routes on first use, and many first requests at once
    # race that load.
    Rails.application.eager_load!
    Rails.application.reload_routes_unless_loaded
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@original_db_config)
    # rubocop:enable RSpec/InstanceVariable
  end

  around do |example|
    original_env = storm_env.keys.index_with { |name| ENV.fetch(name, nil) }
    original_cache = Rails.cache
    original_level = Rails.logger.level
    Rails.logger.level = Logger::WARN
    ENV.update(storm_env)
    example.run
  ensure
    ENV.update(original_env)
    Rails.cache.clear unless Rails.cache.equal?(original_cache)
    Rails.cache = original_cache
    Rails.logger.level = original_level
  end

  after { latency_file.unlink }

  before do
    allow(Net::HTTP).to receive(:start) do |host, port, **options|
      http_class.new.tap { |http| connections << [http, [host, port, options]] }
    end
    # The task saves the round-trip times under tmp/; this run saves them
    # to a folder of its own, so a real run's history is left alone.
    allow(Storm::Latency).to receive(:record).and_wrap_original do |original, latency, shape:, **|
      original.call(latency, path: latency_file.path, shape: shape)
    end
  end

  def storm(max_p95: nil)
    ENV['STORM_MAX_P95'] = max_p95 if max_p95
    $stdout = printed
    task.execute
  ensure
    $stdout = STDOUT
  end

  it 'runs the clients against the server, settles, finds no problem, and saves the round-trip times',
     :aggregate_failures do
    storm(max_p95: '1000000')

    output = printed.string
    expect(output).to include('==> 2 clients for 2s against http://storm.test:3001 (seed 1)', 'No problems.')
    expect(output).to match(/settlements: [1-9]/)
    # One connection per client, and one for the checks, which run on this
    # thread after the clients are done. The task closes all of them.
    expect(connections.map(&:last)).to all(eq(['storm.test', 3001, { read_timeout: 60 }]))
    expect(connections.size).to eq(3)
    expect(connections.map(&:first)).to all(have_attributes(finished: true))
    expect(JSON.parse(File.read(latency_file.path)).keys).to eq(['2 clients, 2s'])
  end

  it 'fails, and names the problem, when the p95 round trip is above STORM_MAX_P95' do
    expect { storm(max_p95: '0') }.to raise_error(SystemExit)

    expect(printed.string).to match(/1 problem\(s\):\n  p95 round trip [\d.]+ ms is above STORM_MAX_P95=0/)
  end

  it 'fails when nothing was settled, since then the storm did not test a settlement' do
    allow(Storm::Run).to receive(:call).and_wrap_original do |original, **options|
      original.call(**options).tap { |result| allow(result).to receive(:settlements).and_return(0) }
    end

    expect { storm }.to raise_error(SystemExit).and output(/the storm did not settle anything/).to_stderr
  end

  it 'refuses to run outside the test environment' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { task.execute }.to raise_error(SystemExit).and output(/Must run in the test environment/).to_stderr
    expect(connections).to be_empty
  end

  # With STORM_SOLID_QUEUE=1 the task starts real bin/jobs processes
  # (Storm::JobsProcess) and checks the queue after the storm
  # (Storm::QueueChecks); both have specs of their own. Here they are
  # stand-ins, and what is checked is how the task uses them.
  describe 'with STORM_SOLID_QUEUE' do
    # Records what the task does with it. Not an RSpec double: the task
    # also stops it from an at_exit hook, after this example is over.
    let(:jobs_process_class) do
      Class.new do
        attr_reader :log, :pid, :events

        def initialize(log:, pid:)
          @log = log
          @pid = pid
          @events = []
        end

        def start
          @events << [:start, Community.exists?]
          self
        end

        def wait_until_registered = @events << :registered
        def stop = @events << :stop
      end
    end
    let(:started) { [] }
    let(:pid_file) { Rails.root.join('tmp/storm_jobs.pid') }
    let(:checked) { [] }

    around do |example|
      kept = pid_file.exist? ? pid_file.read : nil
      example.run
    ensure
      kept ? pid_file.write(kept) : FileUtils.rm_f(pid_file)
    end

    before do
      ENV['STORM_SOLID_QUEUE'] = '1'
      allow(Storm::JobsProcess).to receive(:new) do |log:|
        jobs_process_class.new(log: log, pid: 101 + started.size).tap { started << it }
      end
      allow(Storm::QueueChecks).to receive(:after_storm) do |jobs:, error_log:, drain_timeout:, **|
        checked << { jobs: jobs, error_log: error_log, drain_timeout: drain_timeout,
                     events: jobs.map { it.events.dup } }
        []
      end
      allow(Storm::QueueChecks).to receive(:summary).and_return({ finished: 3, failed: 0 })
    end

    it 'starts each jobs process after the seed, waits for it, and checks the queue with it still running' do
      ENV.update('STORM_JOBS_PROCESSES' => '2', 'STORM_SQ_DRAIN' => '5', 'STORM_ERROR_LOG' => '/tmp/storm-errors.log')

      storm

      expect(started.map(&:log)).to eq([Rails.root.join('tmp/storm_jobs.log'), Rails.root.join('tmp/storm_jobs_2.log')])
      expect(pid_file.read).to eq("101\n102")
      expect(checked.size).to eq(1)
      expect(checked.first).to include(jobs: started, error_log: '/tmp/storm-errors.log', drain_timeout: 5.0)
      # Started once the community is planted, registered before the
      # storm, and not stopped yet when the queue is checked.
      expect(checked.first[:events]).to all(eq([[:start, true], :registered]))
      expect(printed.string).to include('==> 2 bin/jobs process(es) running: pid 101, 102, heartbeat ',
                                        'queue: {finished: 3, failed: 0}', 'No problems.')
    end

    it 'starts one jobs process and waits five minutes for the queue when nothing says otherwise' do
      storm

      expect(started.map(&:log)).to eq([Rails.root.join('tmp/storm_jobs.log')])
      expect(checked.first).to include(error_log: '', drain_timeout: 300.0)
    end

    it 'fails, and names the problem, when the queue checks find one' do
      allow(Storm::QueueChecks).to receive(:after_storm).and_return(['the queue did not drain in 300 s'])

      expect { storm }.to raise_error(SystemExit)

      expect(printed.string).to include("1 problem(s):\n  the queue did not drain in 300 s")
    end
  end

  # Without STORM_SOLID_QUEUE the jobs run in this process, and the error
  # log is still read: the server and this task write to it.
  describe 'with STORM_ERROR_LOG and no Solid Queue' do
    let(:error_log) { Tempfile.new(['storm_errors', '.log']) }

    after { error_log.close! }

    def report(entry)
      error_log.write("#{JSON.generate(entry)}\n")
      error_log.flush
    end

    it 'fails on a report the storm does not allow, and passes over one it does' do
      retried = { 'process' => 'server', 'handled' => true, 'error' => 'ActiveRecord::SerializationFailure',
                  'message' => 'could not serialize access', 'conflict' => true,
                  'context' => { 'attempt' => '1', 'max_attempts' => '3' } }
      swallowed = { 'process' => 'driver', 'handled' => true, 'error' => 'RuntimeError', 'message' => 'boom',
                    'conflict' => false, 'context' => {} }
      report(retried)
      report(swallowed)
      ENV['STORM_ERROR_LOG'] = error_log.path

      expect { storm }.to raise_error(SystemExit)

      expect(printed.string).to include("1 problem(s):\n  driver reported and swallowed: RuntimeError: boom")
      expect(printed.string).not_to include('SerializationFailure')
    end
  end
end

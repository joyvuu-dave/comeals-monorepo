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
      'STORM_MAX_P95' => nil }
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
    # One connection per client, closed when the clients are done. The
    # checks after that run on this thread and open one more.
    expect(connections.map(&:last)).to all(eq(['storm.test', 3001, { read_timeout: 60 }]))
    expect(connections.first(2).map(&:first)).to all(have_attributes(finished: true))
    expect(connections.size).to eq(3)
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
end

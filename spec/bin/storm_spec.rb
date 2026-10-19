# frozen_string_literal: true

require 'rails_helper'

# bin/storm starts a many-threaded Puma and runs rake test:storm against
# it. Bundler, lsof, curl, psql and sleep are fakes here. The fake server
# stays up until the script stops it.
RSpec.describe 'bin/storm' do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/storm') }
  # The fake server marks that it has started, and the fake curl answers
  # only after that, so the calls are logged in the same order every run.
  let(:started) { File.join(sandbox.dir, 'server-started') }
  let(:server_up) { "echo 'Puma starting'; touch #{started}; exec #{sandbox.real('sleep')} 30" }
  let(:answer_once_started) { "until [ -f #{started} ]; do #{sandbox.real('sleep')} 0.01; done" }

  before do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => server_up }),
                 notes: %w[RAILS_ENV INTEGRATION_SERVER INTEGRATION_SERVER_CACHE RAILS_MAX_THREADS WEB_CONCURRENCY
                           RAILS_DB_POOL STORM_URL])
    sandbox.fake('lsof', 'exit 1')
    sandbox.fake('curl', answer_once_started)
    sandbox.fake('psql')
    sandbox.fake('sleep')
  end

  it 'starts Puma with 16 threads, 2 workers and a pool of 18, runs the storm, and resets the database' do
    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq([
                                       'bundle exec rails db:prepare',
                                       'lsof -tiTCP:3001 -sTCP:LISTEN',
                                       'bundle exec rails server -p 3001',
                                       'curl -sf http://localhost:3001/api/v1/version',
                                       'bundle exec rake test:storm',
                                       'psql -q -d comeals_test -c TRUNCATE communities, ledger_check_runs, ' \
                                       'job_runs CASCADE'
                                     ])
    server, storm = sandbox.calls_to('bundle').drop(1)
    expect(server.env).to eq('RAILS_ENV' => 'test', 'INTEGRATION_SERVER' => '1', 'INTEGRATION_SERVER_CACHE' => 'solid',
                             'RAILS_MAX_THREADS' => '16', 'WEB_CONCURRENCY' => '2', 'RAILS_DB_POOL' => '18')
    expect(storm.env).to eq('RAILS_ENV' => 'test', 'STORM_URL' => 'http://localhost:3001')
    expect(result.output).to include('16 threads x 2 workers, pool 18', 'Server log: tmp/storm_server.log')
    expect(result.output).not_to include("lines with 'error'")
  end

  it 'takes its shape from the STORM_ variables' do
    result = sandbox.run(script, env: { 'STORM_THREADS' => '4', 'STORM_WORKERS' => '3', 'STORM_POOL' => '9',
                                        'STORM_PORT' => '4000' })

    expect(result).to be_success, result.output
    server = sandbox.calls_to('bundle')[1]
    expect(server.args).to eq(%w[exec rails server -p 4000])
    expect(server.env).to include('RAILS_MAX_THREADS' => '4', 'WEB_CONCURRENCY' => '3', 'RAILS_DB_POOL' => '9')
  end

  it "uses the worktree's database and port from .env" do
    sandbox.write('.env', "TEST_DB_SUFFIX=_task\nTEST_PORT_INTEGRATION=21060\n")

    sandbox.run(script)

    expect(sandbox.call_lines).to include('bundle exec rails server -p 21060',
                                          'psql -q -d comeals_test_task -c TRUNCATE communities, ' \
                                          'ledger_check_runs, job_runs CASCADE')
  end

  it 'takes the port from TEST_PORT_INTEGRATION before .env' do
    sandbox.write('.env', "TEST_PORT_INTEGRATION=21060\n")

    sandbox.run(script, env: { 'TEST_PORT_INTEGRATION' => '21160' })

    expect(sandbox.call_lines).to include('bundle exec rails server -p 21160')
  end

  it 'refuses to run when something already holds the port' do
    sandbox.fake('lsof', sandbox.answers({ '-tiTCP:*' => 'echo 99',
                                           '-iTCP:*' => sandbox.says("ruby 99 dev TCP *:3001 (LISTEN)\n") }))

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('ERROR: port 3001 is already in use:', 'ruby 99 dev TCP *:3001 (LISTEN)')
    expect(sandbox.call_lines.grep(/rails server/)).to be_empty
    expect(sandbox.calls_to('psql').size).to eq(1)
  end

  it 'waits for the server to answer' do
    counter = File.join(sandbox.dir, 'curls')
    sandbox.fake('curl', "#{answer_once_started}; echo x >> #{counter}; [ \"$(wc -l < #{counter})\" -gt 2 ]")

    result = sandbox.run(script)

    expect(result.output).to include('Waiting for server.. ready!')
    expect(sandbox.calls_to('sleep').size).to eq(2)
  end

  it 'fails with the end of the server log when the server dies' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => 'echo "pool is too small"; exit 1' }))
    sandbox.fake('curl', 'exit 7')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include(' DIED', 'pool is too small')
    expect(sandbox.call_lines.grep(/test:storm/)).to be_empty
  end

  it 'fails with the end of the server log when the server does not answer in 60 seconds' do
    sandbox.fake('curl', 'exit 7')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include(' TIMEOUT', 'Puma starting')
    expect(sandbox.calls_to('curl').size).to eq(60)
  end

  it "prints the server log's error lines after a storm that passed" do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => "echo 'ActiveRecord::Deadlocked error'; " \
                                                                      "#{server_up}" }))

    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(result.output).to include("lines with 'error' in the server log:", '1:ActiveRecord::Deadlocked error')
  end

  it 'fails with the exit code of a failed storm, and still resets the database' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => server_up, 'exec rake test:storm' => 'exit 3' }))

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(3)
    expect(sandbox.calls_to('psql').size).to eq(1)
  end

  # The script saves rake's exit code, prints the server log and its error
  # lines, and then exits with the code. But it runs under set -e, so a
  # failed storm ends the script at the rake line, and the server log is
  # printed only when the storm passed.
  it "prints the server log's error lines after a storm that failed" do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => "echo 'ActiveRecord::Deadlocked error'; " \
                                                                      "#{server_up}",
                                             'exec rake test:storm' => 'exit 3' }))

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(3)
    expect(result.output).to include("lines with 'error' in the server log:", '1:ActiveRecord::Deadlocked error')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# bin/test-integration seeds the test database, builds the SPA, starts a
# Rails test server and runs the Playwright integration suite against it.
# Bundler, npm, npx, lsof, curl, psql and sleep are fakes here. The fake
# server stays up until the script stops it.
RSpec.describe 'bin/test-integration' do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/test-integration') }
  # The fake server marks that it has started, and the fake curl answers
  # only after that, so the calls are logged in the same order every run.
  let(:started) { File.join(sandbox.dir, 'server-started') }
  let(:server_up) { "touch #{started}; exec #{sandbox.real('sleep')} 30" }
  let(:answer_once_started) { "until [ -f #{started} ]; do #{sandbox.real('sleep')} 0.01; done" }

  before do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => server_up }),
                 notes: %w[RAILS_ENV INTEGRATION_FAKE_TODAY INTEGRATION_SERVER])
    sandbox.fake('npm', 'printf "one\ntwo\nthree\nfour\n"')
    sandbox.fake('npx')
    sandbox.fake('lsof', 'exit 1')
    sandbox.fake('curl', answer_once_started)
    sandbox.fake('psql')
    sandbox.fake('sleep')
  end

  it 'prepares, seeds with the frozen date, builds, starts the server, runs the suite, and resets the database' do
    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq([
                                       'bundle exec rails db:prepare',
                                       'bundle exec rails test:seed_integration',
                                       'npm run build',
                                       'lsof -tiTCP:3001 -sTCP:LISTEN',
                                       'bundle exec rails server -p 3001',
                                       'curl -sf http://localhost:3001/api/v1/version',
                                       'npx playwright test --config playwright.integration.config.js',
                                       'psql -q -d comeals_test -c TRUNCATE communities, ledger_check_runs, ' \
                                       'audits CASCADE'
                                     ])
    bundle = sandbox.calls_to('bundle').map(&:env)
    expect(bundle).to eq([{ 'RAILS_ENV' => 'test' },
                          { 'RAILS_ENV' => 'test', 'INTEGRATION_FAKE_TODAY' => '2026-01-15' },
                          { 'RAILS_ENV' => 'test', 'INTEGRATION_FAKE_TODAY' => '2026-01-15',
                            'INTEGRATION_SERVER' => '1' }])
    expect(result.output).to include("two\nthree\nfour\n", 'Waiting for server ready!',
                                     'Stopping Rails test server (PID ')
    expect(result.output).not_to include("one\n")
  end

  # The date is unset for db:prepare: Rails refuses a migration dated
  # after "now", and the frozen date is in the past.
  it 'takes the frozen date from INTEGRATION_FAKE_TODAY, but not for db:prepare' do
    sandbox.run(script, env: { 'INTEGRATION_FAKE_TODAY' => '2026-03-08' })

    expect(sandbox.calls_to('bundle').map { |call| call.env['INTEGRATION_FAKE_TODAY'] })
      .to eq([nil, '2026-03-08', '2026-03-08'])
  end

  it "uses the worktree's database and port from .env, and passes on the test file it is given" do
    sandbox.write('.env', "TEST_DB_SUFFIX=_task\nTEST_PORT_INTEGRATION=21060\n")

    result = sandbox.run(script, 'auth.spec.js')

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to include('bundle exec rails server -p 21060',
                                          'curl -sf http://localhost:21060/api/v1/version',
                                          'npx playwright test --config playwright.integration.config.js auth.spec.js',
                                          'psql -q -d comeals_test_task -c TRUNCATE communities, ' \
                                          'ledger_check_runs, audits CASCADE')
  end

  it 'takes the port from the environment before .env' do
    sandbox.write('.env', "TEST_PORT_INTEGRATION=21060\n")

    sandbox.run(script, env: { 'TEST_PORT_INTEGRATION' => '21160' })

    expect(sandbox.call_lines).to include('bundle exec rails server -p 21160')
  end

  it 'reuses the last build with SKIP_BUILD=1' do
    result = sandbox.run(script, env: { 'SKIP_BUILD' => '1' })

    expect(result.output).to include('Reusing existing frontend build (SKIP_BUILD=1)')
    expect(sandbox.calls_to('npm')).to be_empty
  end

  it 'refuses to run when something already holds the port' do
    sandbox.fake('lsof', sandbox.answers({ '-tiTCP:*' => 'echo 99',
                                           '-iTCP:*' => sandbox.says("ruby 99 dev TCP *:3001 (LISTEN)\n") }))

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('ERROR: port 3001 is already in use:', 'ruby 99 dev TCP *:3001 (LISTEN)',
                                     'Kill that process')
    expect(sandbox.call_lines.grep(/rails server|playwright/)).to be_empty
    expect(sandbox.calls_to('psql').size).to eq(1)
  end

  it 'waits for the server to answer' do
    counter = File.join(sandbox.dir, 'curls')
    sandbox.fake('curl', "#{answer_once_started}; echo x >> #{counter}; [ \"$(wc -l < #{counter})\" -gt 2 ]")

    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(result.output).to include('Waiting for server.. ready!')
    expect(sandbox.calls_to('sleep').size).to eq(2)
  end

  it 'fails with the end of the server log when the server dies' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => 'echo "Address already in use"; exit 1' }))
    sandbox.fake('curl', 'exit 7')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include(' DIED', 'ERROR: Rails server exited during startup', 'Address already in use')
    expect(sandbox.calls_to('npx')).to be_empty
  end

  it 'fails with the end of the server log when the server does not answer in 30 seconds' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails server *' => "echo booting; #{server_up}" }))
    sandbox.fake('curl', 'exit 7')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include(' TIMEOUT', 'failed to start within 30 seconds', 'booting')
    expect(sandbox.calls_to('curl').size).to eq(30)
    expect(sandbox.calls_to('npx')).to be_empty
  end

  it 'fails with the exit code of a failed suite, and still resets the database' do
    sandbox.fake('npx', 'exit 1')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(sandbox.calls_to('psql').size).to eq(1)
  end
end

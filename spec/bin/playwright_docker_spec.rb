# frozen_string_literal: true

require 'rails_helper'

# bin/lib/playwright-docker, which CI's browser jobs use to run the
# browsers in Playwright's Docker image instead of installing Ubuntu
# packages with apt (#252). Docker, node, curl, sleep and the wrapped
# command are fakes here.
RSpec.describe 'bin/lib/playwright-docker', bash_coverage: BashCoverage.new('spec/bin/playwright_docker_spec.rb') do
  include_context 'with a script sandbox'

  let(:image) { 'mcr.microsoft.com/playwright:v1.58.2-noble' }

  before do
    sandbox.fake('node', 'echo 1.58.2')
    sandbox.fake('curl')
    sandbox.fake('sleep')
    sandbox.fake('timeout')
    docker(running: 'true')
    sandbox.fake('npm', notes: %w[PW_TEST_CONNECT_WS_ENDPOINT])
  end

  def docker(running:)
    sandbox.fake('docker', sandbox.answers({ 'run *' => 'echo c0ffee',
                                             'inspect *' => "echo #{running}",
                                             'logs *' => 'echo "the server log"' }))
  end

  def pull(minutes = 5) = "timeout --kill-after=30s #{minutes}m docker pull --quiet #{image}"

  def run(*, env: {}) = sandbox.run_script('bin/lib/playwright-docker', *, env:)

  it 'starts the browser server in the image that matches the Playwright version, then runs the command' do
    result = run('npm', 'run', 'test:e2e')

    expect(result.exitstatus).to eq(0), result.out + result.err
    expect(sandbox.call_lines('node')).to eq(
      ["node -p require('#{sandbox.root}/package-lock.json').packages['node_modules/@playwright/test'].version"]
    )
    expect(sandbox.call_lines('docker')).to eq(
      ['docker run --detach --init --ipc=host --network=host --user pwuser ' \
       "-v #{sandbox.root}:/work:ro -w /work #{image} " \
       'node node_modules/@playwright/test/cli.js run-server --host 127.0.0.1 --port 3039 --unsafe',
       'docker rm --force c0ffee']
    )
    expect(sandbox.call_lines('timeout')).to eq([pull])
    npm = sandbox.calls_to('npm').sole
    expect(npm.args).to eq(%w[run test:e2e])
    expect(npm.env).to eq('PW_TEST_CONNECT_WS_ENDPOINT' => 'ws://127.0.0.1:3039/')
  end

  it 'takes another port from PLAYWRIGHT_SERVER_PORT' do
    run('npm', 'test', env: { 'PLAYWRIGHT_SERVER_PORT' => '4100' })

    expect(sandbox.call_lines('curl').uniq).to eq(['curl -s -o /dev/null http://127.0.0.1:4100/'])
    expect(sandbox.calls_to('npm').sole.env).to eq('PW_TEST_CONNECT_WS_ENDPOINT' => 'ws://127.0.0.1:4100/')
  end

  it 'waits for the server to answer before it runs the command' do
    counter = File.join(sandbox.dir, 'curls')
    # Not up for the first two tries.
    sandbox.fake('curl', "echo x >> #{counter}; [ \"$(wc -l < #{counter})\" -gt 2 ]")

    result = run('npm', 'test')

    expect(result.exitstatus).to eq(0), result.out + result.err
    expect(sandbox.calls_to('curl').size).to eq(4) # three in the loop, one after it
    expect(sandbox.calls_to('sleep').size).to eq(2)
    expect(sandbox.calls_to('npm').size).to eq(1)
  end

  it 'stops, with the server output, when the container stops before the server answers' do
    sandbox.fake('curl', 'exit 7')
    docker(running: 'false')

    result = run('npm', 'test')

    expect(result.exitstatus).to eq(1)
    expect(result.err).to eq("The browser server stopped before it answered. Its output:\nthe server log\n")
    expect(sandbox.calls_to('npm')).to be_empty
    expect(sandbox.call_lines('docker').last).to eq('docker rm --force c0ffee')
  end

  it 'stops, with the server output, when the server has not answered after a minute' do
    sandbox.fake('curl', 'exit 7')

    result = run('npm', 'test')

    expect(result.exitstatus).to eq(1)
    expect(result.err).to eq(
      "The browser server did not answer on port 3039 within a minute. Its output:\nthe server log\n"
    )
    expect(sandbox.calls_to('sleep').size).to eq(60)
    expect(sandbox.calls_to('npm')).to be_empty
  end

  # timeout exits 124 when it stopped the pull.
  it 'tries the pull once more when the first try fails' do
    counter = File.join(sandbox.dir, 'pulls')
    sandbox.fake('timeout', "echo x >> #{counter}; [ \"$(wc -l < #{counter})\" -gt 1 ] || exit 124")

    result = run('npm', 'test')

    expect(result.exitstatus).to eq(0), result.out + result.err
    expect(sandbox.call_lines('timeout')).to eq([pull, pull])
    expect(result.err).to eq("docker pull #{image} failed or ran out of time (5m) on try 1 of 2.\n")
    expect(sandbox.calls_to('npm').size).to eq(1)
  end

  it 'stops, naming the image, when both pulls fail' do
    sandbox.fake('timeout', 'exit 124')

    result = run('npm', 'test', env: { 'PLAYWRIGHT_PULL_MINUTES' => '2' })

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines('timeout')).to eq([pull(2), pull(2)])
    expect(result.err).to eq(<<~ERR)
      docker pull #{image} failed or ran out of time (2m) on try 1 of 2.
      docker pull #{image} failed or ran out of time (2m) on try 2 of 2.
      Could not pull #{image} after 2 tries.
    ERR
    expect(sandbox.calls_to('docker')).to be_empty
    expect(sandbox.calls_to('npm')).to be_empty
  end

  it "fails with the command's exit status, and still removes the container" do
    sandbox.fake('npm', 'exit 3')

    result = run('npm', 'test')

    expect(result.exitstatus).to eq(3)
    expect(sandbox.call_lines('docker').last).to eq('docker rm --force c0ffee')
  end

  # The jobs that used to install the browsers' Ubuntu packages with apt
  # run them through this script now, so no apt step can stop them.
  it 'is how the CI browser jobs run their suites' do
    ci = YAML.safe_load_file(Rails.root.join('.github/workflows/ci.yml').to_s)
    runs = %w[node-e2e-tests integration-tests].index_with do |job|
      ci['jobs'][job]['steps'].filter_map { it['run'] }
    end

    expect(runs).to eq(
      'node-e2e-tests' => ['npm ci', 'bin/lib/playwright-docker npm run test:e2e',
                           'bin/lib/playwright-docker bin/visual-coverage'],
      'integration-tests' => ['npm ci', 'bin/rails db:schema:load', 'bin/lib/playwright-docker bin/test-integration']
    )
  end
end

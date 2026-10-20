# frozen_string_literal: true

require 'rails_helper'

# bin/visual-linux runs the visual suite in the Playwright Linux image,
# with Rails for the admin pages on the host. Docker, node, curl and the
# admin server are fakes here. The script's first line names /bin/bash,
# which is bash 3.2 on a Mac, so the spec runs it with the bash on the
# PATH, the way CI's Linux runner does.
RSpec.describe 'bin/visual-linux', bash_coverage: BashCoverage.new('spec/bin/visual_linux_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/visual-linux') }
  let(:image) { 'mcr.microsoft.com/playwright:v1.58.2-noble' }

  before do
    sandbox.fake('node', 'echo 1.58.2')
    sandbox.fake('curl')
    sandbox.fake('sleep')
    sandbox.fake('docker', notes: %w[VITE_PUSHER_KEY])
    # The admin server stays up until the script stops it.
    sandbox.fake_script('tests/admin/server.sh', "exec #{sandbox.real('sleep')} 30")
  end

  def run(*, env: {})
    sandbox.run(sandbox.bash, script, *, env: env)
  end

  def docker_command
    call = sandbox.calls_to('docker').sole
    expect(call.args.first(13)).to eq(['run', '--rm', '--ipc=host', '--add-host=host.docker.internal:host-gateway',
                                       '-e', 'VITE_PUSHER_KEY', '-e', 'VITE_PUSHER_CLUSTER',
                                       '-e', 'PLAYWRIGHT_SKIP_ADMIN=1',
                                       '-e', 'PLAYWRIGHT_ADMIN_HOST=host.docker.internal', '-v'])
    expect(call.args[13]).to eq("#{sandbox.root}:/work")
    expect(call.args[14..19]).to eq(['-v', 'comeals-playwright-modules:/work/node_modules', '-w', '/work', image,
                                     'bash'])
    call.args[20..]
  end

  it 'compares both visual specs against the goldens, in the image that matches the Playwright version' do
    result = run

    expect(result).to be_success, result.output
    expect(result.output).to include('Starting Rails for the admin pages on port 3038')
    expect(sandbox.call_lines).to include(
      "node -p require('./package-lock.json').packages['node_modules/@playwright/test'].version",
      'curl -s -o /dev/null -H Host: admin.lvh.me http://127.0.0.1:3038/login'
    )
    expect(docker_command).to eq(['-c', 'npm install --no-audit --no-fund && npx playwright test ' \
                                        'tests/e2e/visual.spec.js tests/admin/visual.spec.js '])
  end

  it 'rewrites every golden with --update, for only the specs named' do
    result = run('--update', 'tests/admin/visual.spec.js')

    expect(result).to be_success, result.output
    expect(docker_command).to eq(['-c', 'npm install --no-audit --no-fund && npx playwright test ' \
                                        'tests/admin/visual.spec.js --update-snapshots=all'])
  end

  it "takes the admin port from the worktree's .env" do
    sandbox.write('.env', "TEST_PORT_ADMIN_E2E=21062\n")

    run

    expect(sandbox.call_lines).to include('curl -s -o /dev/null -H Host: admin.lvh.me http://127.0.0.1:21062/login')
  end

  it 'takes the admin port from the environment first' do
    sandbox.write('.env', "TEST_PORT_ADMIN_E2E=21062\n")

    run(env: { 'TEST_PORT_ADMIN_E2E' => '21162' })

    expect(sandbox.call_lines).to include('curl -s -o /dev/null -H Host: admin.lvh.me http://127.0.0.1:21162/login')
  end

  it 'waits for Rails to answer before it starts the container' do
    counter = File.join(sandbox.dir, 'curls')
    # Not up for the first two tries.
    sandbox.fake('curl', "echo x >> #{counter}; [ \"$(wc -l < #{counter})\" -gt 2 ]")

    result = run

    expect(result).to be_success, result.output
    expect(sandbox.calls_to('curl').size).to eq(4) # three in the loop, one after it
    expect(sandbox.calls_to('sleep').size).to eq(2)
    expect(sandbox.calls_to('docker').size).to eq(1)
  end

  it 'stops when the admin server dies before it answers' do
    sandbox.fake('curl', 'exit 7')
    sandbox.fake_script('tests/admin/server.sh', 'exit 1')

    result = run

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("Rails did not start; see #{sandbox.dir}/tmp/comeals-admin-e2e.")
    expect(sandbox.calls_to('docker')).to be_empty
  end

  it 'stops when Rails has not answered after two minutes' do
    sandbox.fake('curl', 'exit 7')

    result = run

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('Rails did not answer on port 3038 within two minutes')
    expect(sandbox.calls_to('sleep').size).to eq(120)
    expect(sandbox.calls_to('docker')).to be_empty
  end

  it 'fails when the suite in the container fails' do
    sandbox.fake('docker', 'exit 1')

    expect(run.exitstatus).to eq(1)
  end
end

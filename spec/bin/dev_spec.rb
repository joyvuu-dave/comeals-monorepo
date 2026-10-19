# frozen_string_literal: true

require 'rails_helper'

# bin/dev frees the dev ports when a leftover session from this folder
# holds them, then starts foreman. lsof, ps, sleep and bundle are fakes.
# kill is a bash builtin, so the "leftover server" is a real process this
# spec starts and owns, and fake lsof reports it while it is alive.
RSpec.describe 'bin/dev' do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/dev') }
  let(:pid_file) { sandbox.write('tmp/pids/server.pid', '123') }
  let(:server) { File.join(sandbox.dir, 'server') }

  before do
    pid_file
    sandbox.fake('lsof')
    sandbox.fake('ps')
    sandbox.fake('sleep')
    sandbox.fake('bundle')
  end

  after do
    pid = File.exist?(server) && File.read(server).to_i
    Process.kill('KILL', pid) if pid
  rescue Errno::ESRCH
    nil
  end

  # A process that holds port 3000 for this spec, and a fake lsof that
  # names it on that port only while it is alive.
  def leftover_server(ignore_term: false)
    command = ignore_term ? 'trap "" TERM; while :; do /bin/sleep 1; done' : 'exec /bin/sleep 30'
    # Without bashcov's trace settings: this loop is not a script measured.
    pid = Process.spawn({ 'SHELLOPTS' => nil, 'BASH_XTRACEFD' => nil }, 'bash', '-c', command,
                        %i[out err] => File::NULL)
    Process.detach(pid)
    File.write(server, pid.to_s)
    sandbox.fake('lsof', <<~BASH)
      case "$*" in
        *TCP:3000*) kill -0 #{pid} 2>/dev/null && echo #{pid} ;;
      esac
      exit 0
    BASH
    pid
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it 'starts foreman with the arguments it was given when both ports are free' do
    result = sandbox.run(script, 'web=1')

    expect(result).to be_success, result.output
    expect(result.output).to include('Comeals:       http://localhost:3036')
    expect(sandbox.call_lines).to eq(['lsof -nP -tiTCP:3000 -sTCP:LISTEN', 'lsof -nP -tiTCP:3036 -sTCP:LISTEN',
                                      'rm -f tmp/pids/server.pid', 'bundle exec foreman start -f Procfile.dev web=1'])
    expect(File).not_to exist(pid_file)
  end

  it 'stops a leftover server that was started from this folder, then starts' do
    pid = leftover_server
    sandbox.fake('ps', "echo 'puma 7.0 (tcp://localhost:3000) [root]'")

    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(result.output).to include("Stopping leftover Rails server (pid #{pid}) on port 3000...")
    expect(alive?(pid)).to be(false)
    expect(sandbox.calls_to('bundle').size).to eq(1)
  end

  it 'gives up after five seconds when the leftover server does not stop' do
    pid = leftover_server(ignore_term: true)
    sandbox.fake('ps', "echo 'puma 7.0 (tcp://localhost:3000) [root]'")

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("Port 3000 is still busy. Stop pid #{pid} yourself", "kill -9 #{pid}")
    expect(sandbox.calls_to('sleep').size).to eq(10)
    expect(sandbox.calls_to('bundle')).to be_empty
  end

  # A server from a sibling worktree is someone else's running session.
  it 'leaves alone a server that was not started from this folder, and says how to stop it' do
    pid = leftover_server
    sandbox.fake('ps', "echo '#{pid} puma 7.0 (tcp://localhost:3000) [comeals-other-task]'")

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('Port 3000 is used by a program that was not started from this directory',
                                     "comeals-other-task]\n", "    kill #{pid}")
    expect(alive?(pid)).to be(true)
    expect(sandbox.calls_to('bundle')).to be_empty
  end
end

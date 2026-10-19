# frozen_string_literal: true

require 'rails_helper'

# bin/prod builds the production bundle and serves it from Rails in the
# production environment. lsof, npm and bundle are fakes here.
RSpec.describe 'bin/prod' do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/prod') }
  let(:pid_file) { sandbox.write('tmp/pids/server.pid', '123') }
  let(:production_env) do
    { 'RAILS_ENV' => 'production', 'LOCAL_PRODUCTION' => '1', 'SECRET_KEY_BASE_DUMMY' => '1',
      'RAILS_LOG_TO_STDOUT' => '1', 'SKYLIGHT_ENABLED' => 'false' }
  end

  before do
    pid_file
    sandbox.fake('lsof')
    notes = %w[RAILS_ENV LOCAL_PRODUCTION SECRET_KEY_BASE_DUMMY RAILS_LOG_TO_STDOUT SKYLIGHT_ENABLED VITE_PUSHER_KEY]
    sandbox.fake('npm', notes: notes)
    sandbox.fake('bundle', notes: notes)
  end

  it 'builds, precompiles and starts Rails in the production environment, with .env loaded' do
    sandbox.write('.env', "VITE_PUSHER_KEY=key-from-env-file\n")

    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq(['lsof -ti :3000 -sTCP:LISTEN', 'rm -f tmp/pids/server.pid', 'npm run build',
                                      'bundle exec rake assets:precompile', 'bundle exec rails server -p 3000'])
    expect(sandbox.calls_to('bundle').last.env).to eq(production_env.merge('VITE_PUSHER_KEY' => 'key-from-env-file'))
    expect(File).not_to exist(pid_file)
    expect(result.output).to include('Comeals (production mode):    http://localhost:3000')
  end

  it 'runs without a .env' do
    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(sandbox.calls_to('bundle').last.env).to eq(production_env)
  end

  it 'refuses while port 3000 is in use, and prints the command that stops it' do
    sandbox.fake('lsof', sandbox.answers(
                           { '-ti :3000 -sTCP:LISTEN' => sandbox.says("101\n202\n"),
                             '-i :3000 -sTCP:LISTEN' => sandbox.says(<<~LSOF) }
                               COMMAND PID USER FD TYPE
                               ruby    101 dev  9u IPv4
                               ruby    101 dev  10u IPv6
                               node    202 dev  20u IPv4
                             LSOF
                         ))

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("COMMAND PID USER FD TYPE\nruby    101 dev  9u IPv4\nnode    202 dev  20u IPv4\n",
                                     'kill 101 202')
    expect(File).to exist(pid_file)
    expect(sandbox.calls_to('npm')).to be_empty
  end

  it 'stops when the build fails' do
    sandbox.fake('npm', 'exit 1')

    expect(sandbox.run(script).exitstatus).to eq(1)
    expect(sandbox.calls_to('bundle')).to be_empty
  end
end

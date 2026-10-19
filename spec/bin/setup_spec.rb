# frozen_string_literal: true

require 'rails_helper'

# bin/setup sets up a development checkout. Every command it runs is a fake
# here (spec/bin/preload/fake_system.rb).
RSpec.describe 'bin/setup' do
  let(:script) { Rails.root.join('bin/setup').to_s }
  let(:log) { Tempfile.new('system') }
  let(:answers) do
    {
      'git config core.hooksPath .githooks' => true,
      'command -v gitleaks >/dev/null 2>&1' => true,
      'gem install bundler --conservative' => true,
      'bundle check' => true,
      'bin/rails db:prepare' => true,
      'bin/rails log:clear tmp:clear' => true,
      'bin/rails restart' => true
    }
  end

  after { log.close! }

  def setup(changes = {})
    env = { 'FAKE_SYSTEM_LOG' => log.path, 'FAKE_SYSTEM_ANSWERS' => answers.merge(changes).to_json }
    out, status = run_ruby_script(script, env: env, preload: %w[fake_system], chdir: Dir.tmpdir)
    [out, status, File.read(log.path).lines.map(&:chomp)]
  end

  it 'sets the hooks folder, installs the gems, prepares the database, and restarts the server' do
    out, status, commands = setup

    expect(status).to be_success, out
    expect(commands).to eq(answers.keys)
    expect(out).to eq("== Configuring git hooks ==\n\n== Installing dependencies ==\n\n" \
                      "== Preparing database ==\n\n== Removing old logs and tempfiles ==\n\n" \
                      "== Restarting application server ==\n")
  end

  it 'installs the gems when bundle check finds some missing' do
    _, status, commands = setup('bundle check' => false, 'bundle install' => true)

    expect(status).to be_success
    expect(commands).to include('bundle check', 'bundle install')
  end

  it 'installs gitleaks with Homebrew when it is missing' do
    out, status, commands = setup('command -v gitleaks >/dev/null 2>&1' => false,
                                  'command -v brew >/dev/null 2>&1' => true, 'brew install gitleaks' => true)

    expect(status).to be_success, out
    expect(out).to include('== Installing gitleaks ==')
    expect(commands[1..3]).to eq(['command -v gitleaks >/dev/null 2>&1', 'command -v brew >/dev/null 2>&1',
                                  'brew install gitleaks'])
  end

  it 'stops and says how to install gitleaks when there is no Homebrew' do
    out, status, commands = setup('command -v gitleaks >/dev/null 2>&1' => false,
                                  'command -v brew >/dev/null 2>&1' => false)

    expect(status.exitstatus).to eq(1)
    expect(out).to include('gitleaks is not installed and Homebrew is not here. Install it from ' \
                           'https://github.com/gitleaks/gitleaks#installing and run bin/setup again.')
    expect(commands.last).to eq('command -v brew >/dev/null 2>&1')
  end

  it 'stops at the first command that fails, and names it' do
    out, status, commands = setup('bin/rails db:prepare' => false)

    expect(status.exitstatus).to eq(1)
    expect(out).to include("== Command [\"bin/rails db:prepare\"] failed ==\n")
    expect(out).not_to include('== Removing old logs')
    expect(commands.last).to eq('bin/rails db:prepare')
  end
end

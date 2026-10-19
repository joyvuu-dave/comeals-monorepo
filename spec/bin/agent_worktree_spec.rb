# frozen_string_literal: true

require 'rails_helper'

# bin/agent-worktree makes a worktree for one agent task, with its own test
# database and test ports. It runs here against a throwaway repository
# (spec/support/throwaway_repository.rb); bundle and npm are fakes.
RSpec.describe 'bin/agent-worktree' do
  include ThrowawayRepository

  let(:script) { File.join(ScriptSandbox::REPO, 'bin/agent-worktree') }

  before do
    make_repository
    sandbox.fake('bundle', notes: %w[RAILS_ENV])
    sandbox.fake('npm')
  end

  def run(*, chdir: repo) = sandbox.run(script, *, env: git_env, chdir: chdir)

  # The first port of the task's block, the way the script picks it.
  def first_port(name)
    sum = Open3.capture2('cksum', stdin_data: name).first.split.first.to_i
    21_000 + ((sum % 100) * 10)
  end

  def env_file(name) = File.read(File.join(worktree_path(name), '.env'))

  it 'makes the worktree on a new branch from main, with its own database and ports, and installs it' do
    File.write(File.join(repo, '.env'), "VITE_PUSHER_KEY=key\n")
    port = first_port('fix-it')

    result = run('fix-it')

    expect(result).to be_success, result.output
    worktree = worktree_path('fix-it')
    expect(git('rev-parse', '--abbrev-ref', 'HEAD', chdir: worktree)).to eq('agent/fix-it')
    expect(git('rev-parse', 'HEAD', chdir: worktree)).to eq(git('rev-parse', 'main'))
    expect(env_file('fix-it')).to eq(<<~ENV)
      VITE_PUSHER_KEY=key

      # Added by bin/agent-worktree: this worktree's own test database
      # and test-server ports. The admin e2e suite also uses its own
      # database, comeals_admin_e2e_fix_it (tests/admin/server.sh).
      TEST_DB_SUFFIX=_fix_it
      TEST_PORT_INTEGRATION=#{port}
      TEST_PORT_E2E=#{port + 1}
      TEST_PORT_ADMIN_E2E=#{port + 2}
    ENV
    expect(sandbox.calls.map { |call| [call.line, call.pwd, call.env] }).to eq(
      [['bundle install --quiet', worktree, {}],
       ['npm install --no-audit --no-fund --loglevel=error', worktree, {}],
       ['bundle exec rails db:test:prepare', worktree, { 'RAILS_ENV' => 'test' }]]
    )
    expect(result.output).to include("Ready. Work in #{worktree} on branch agent/fix-it.",
                                     'Tests here use comeals_test_fix_it',
                                     "ports #{port}-#{port + 2}", 'bin/agent-worktree-done fix-it')
  end

  it 'writes only its own lines to .env when the main checkout has none' do
    run('fix-it')

    expect(env_file('fix-it')).to start_with("\n# Added by bin/agent-worktree")
  end

  it 'takes the next block when a sibling worktree already has the first one' do
    port = first_port('fix-it')
    sandbox.write(File.join(worktree_path('other'), '.env'), "TEST_PORT_INTEGRATION=#{port}\n")

    run('fix-it')

    expect(env_file('fix-it')).to include("TEST_PORT_INTEGRATION=#{port + 10}\n")
  end

  # The blocks run from 21000 to 21990; after the last one comes the first.
  it 'goes back to the first block after the last one' do
    name = ('a'..'zz').find { |candidate| first_port(candidate) == 21_990 }
    sandbox.write(File.join(worktree_path('other'), '.env'), "TEST_PORT_INTEGRATION=21990\n")

    run(name)

    expect(env_file(name)).to include("TEST_PORT_INTEGRATION=21000\n")
  end

  it 'refuses when every block is taken' do
    100.times do |n|
      sandbox.write(File.join(worktree_path("other-#{n}"), '.env'), "TEST_PORT_INTEGRATION=#{21_000 + (n * 10)}\n")
    end

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('No free port block: all 100 are claimed')
    expect(sandbox.calls).to be_empty
  end

  it 'stops when git cannot make the worktree, for example when the branch is there already' do
    git('branch', 'agent/fix-it')

    result = run('fix-it')

    expect(result.exitstatus).not_to eq(0)
    expect(result.output).to include("a branch named 'agent/fix-it' already exists")
    expect(sandbox.calls).to be_empty
  end

  it 'refuses to run from inside a worktree' do
    run('first')

    result = run('second', chdir: worktree_path('first'))

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("Run this from the main checkout, not from inside a worktree.\n")
    expect(branches).not_to include('agent/second')
  end

  [[], %w[two names], ['Fix-It'], ['-fix'], ['fix_it'], ['a' * 41]].each do |args|
    it "prints the usage for #{args.inspect}" do
      result = run(*args)

      expect(result.exitstatus).to eq(1)
      expect(result.output).to start_with('usage: bin/agent-worktree <task-name>')
      expect(branches).to eq(['main'])
    end
  end

  it 'takes a name of 40 characters' do
    expect(run('a' * 40)).to be_success
  end
end

# frozen_string_literal: true

require 'rails_helper'

# bin/agent-merge lands a finished agent branch: a fast-forward merge into
# main, a push, a migrate when the branch added one, and the cleanup. It
# runs here against a throwaway repository with a bare origin
# (spec/support/throwaway_repository.rb). The repository's
# bin/agent-worktree-done is the real script; its bin/rails and dropdb
# are fakes.
RSpec.describe 'bin/agent-merge' do
  include ThrowawayRepository

  let(:script) { File.join(ScriptSandbox::REPO, 'bin/agent-merge') }
  let(:worktree) { worktree_path('fix-it') }
  let(:rails) { '' }

  before do
    sandbox.fake('dropdb')
    sandbox.fake_script('bin/rails', rails)
    make_repository('README.md' => "Comeals\n", 'db/structure.sql' => "-- schema\n",
                    'bin/agent-worktree-done' => ThrowawayRepository::RealScript.new('bin/agent-worktree-done'))
    git('worktree', 'add', '-q', '-b', 'agent/fix-it', worktree, 'main')
  end

  def run(*, chdir: repo) = sandbox.run(script, *, env: git_env, chdir: chdir)

  def origin_main = git('rev-parse', 'main', chdir: origin)

  # A commit pushed to origin from another clone, as if someone else had
  # pushed it.
  def push_from_elsewhere(files)
    other = File.join(sandbox.dir, 'other-clone')
    git('clone', '-q', origin, other, chdir: sandbox.dir) unless File.exist?(other)
    pushed = commit(files, chdir: other)
    git('push', '-q', 'origin', 'main', chdir: other)
    pushed
  end

  def expect_nothing_merged(head)
    expect(git('rev-parse', 'main')).to eq(head)
    expect(origin_main).to eq(head)
    expect(branches).to include('agent/fix-it')
    expect(File).to exist(worktree)
  end

  it 'merges the branch, pushes main, removes the worktree and deletes the branch' do
    work = commit({ 'app.rb' => "1\n" }, chdir: worktree)

    result = run('fix-it')

    expect(result).to be_success, result.output
    expect(git('rev-parse', 'main')).to eq(work)
    expect(origin_main).to eq(work)
    expect(File).not_to exist(worktree)
    expect(branches).to eq(['main'])
    expect(sandbox.call_lines).to eq(['dropdb --if-exists comeals_test_fix_it',
                                      'dropdb --if-exists comeals_admin_e2e_fix_it'])
    expect(result.output).to end_with("\nMerged agent/fix-it into main, pushed, and cleaned up.\n")
  end

  context 'when the branch adds a migration' do
    before { commit({ 'db/migrate/20261019000000_add_thing.rb' => "class AddThing; end\n" }, chdir: worktree) }

    it 'migrates the development database' do
      result = run('fix-it')

      expect(result).to be_success, result.output
      expect(sandbox.calls_to('bin/rails').map(&:line)).to eq(['bin/rails db:migrate'])
      expect(result.output).to include('==> branch added migrations; migrating the development database')
      expect(result.output).not_to include('dump differs')
    end

    context 'when the dump of the development database differs from the merged file' do
      let(:rails) { 'echo "-- the same rule in another form" >> db/structure.sql' }

      it 'prints the difference and puts back the merged db/structure.sql' do
        result = run('fix-it')

        expect(result).to be_success, result.output
        expect(result.output).to include("the development database's dump differs from the merged db/structure.sql",
                                         '+-- the same rule in another form',
                                         '==> put back the merged db/structure.sql')
        expect(File.read(File.join(repo, 'db/structure.sql'))).to eq("-- schema\n")
        expect(git('status', '--porcelain')).to be_empty
      end
    end
  end

  it 'brings main up to date with origin first, when only origin moved' do
    pushed = push_from_elsewhere('other.rb' => "1\n")
    git('fetch', '-q')
    git('rebase', '-q', 'origin/main', chdir: worktree)
    work = commit({ 'app.rb' => "1\n" }, chdir: worktree)

    result = run('fix-it')

    expect(result).to be_success, result.output
    expect(git('rev-parse', 'main')).to eq(work)
    expect(git('rev-list', '--count', "#{pushed}..main")).to eq('1')
  end

  # The merge and the push are done by then; the uncommitted work stays
  # where it was, and so does the branch.
  it 'stops at the cleanup when the worktree has uncommitted changes' do
    work = commit({ 'app.rb' => "1\n" }, chdir: worktree)
    File.write(File.join(worktree, 'draft.rb'), "1\n")

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(origin_main).to eq(work)
    expect(result.output).to include('The worktree at ../comeals-fix-it has uncommitted changes:')
    expect(File.read(File.join(worktree, 'draft.rb'))).to eq("1\n")
    expect(branches).to include('agent/fix-it')
  end

  it 'skips the cleanup when the worktree is gone already' do
    commit({ 'app.rb' => "1\n" }, chdir: worktree)
    git('worktree', 'remove', worktree)

    result = run('fix-it')

    expect(result).to be_success, result.output
    expect(result.output).to include('No worktree at ../comeals-fix-it (already removed); skipping cleanup.')
    expect(branches).to eq(['main'])
    expect(sandbox.calls).to be_empty
  end

  it 'refuses a branch that is not a fast-forward of main' do
    commit({ 'app.rb' => "1\n" }, chdir: worktree)
    head = commit({ 'main.rb' => "1\n" })
    git('push', '-q')

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("agent/fix-it is not a fast-forward of main. Rebase it in its worktree:\n  " \
                                     "cd ../comeals-fix-it && git rebase main\n")
    expect_nothing_merged(head)
  end

  it 'refuses when main has commits that origin does not' do
    commit({ 'app.rb' => "1\n" }, chdir: worktree)
    head = git('rev-parse', 'main')
    local = commit({ 'local.rb' => "1\n" }, message: 'waiting on a fix')

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    short = git('rev-parse', '--short', local)
    expect(result.output).to include("main already has commit(s) that origin/main does not:\n" \
                                     "#{short} waiting on a fix\n", 'them first (git push)')
    expect(origin_main).to eq(head)
    expect(branches).to include('agent/fix-it')
  end

  it 'refuses when main and origin have each moved' do
    push_from_elsewhere('other.rb' => "1\n")
    commit({ 'local.rb' => "1\n" })

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("Local main and origin/main have each moved. Sort that out by\n" \
                                "hand before merging anything.\n")
    expect(branches).to include('agent/fix-it')
  end

  it 'refuses when there is no branch of that name' do
    result = run('other')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("No branch named agent/other.\n")
  end

  it 'refuses, and leaves the changes alone, when the main checkout has uncommitted changes' do
    commit({ 'app.rb' => "1\n" }, chdir: worktree)
    head = git('rev-parse', 'main')
    File.write(File.join(repo, 'README.md'), "changed\n")

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("The main checkout has uncommitted changes:\n M README.md\n")
    expect(File.read(File.join(repo, 'README.md'))).to eq("changed\n")
    expect_nothing_merged(head)
  end

  it 'refuses when the main checkout is not on main' do
    git('checkout', '-q', '-b', 'side')

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("The main checkout is on 'side', not main.\n" \
                                "Switch it back to main first: git checkout main\n")
  end

  it 'refuses to run from inside a worktree' do
    result = run('fix-it', chdir: worktree)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("Run this from the main checkout, not from inside a worktree.\n")
  end

  [[], %w[two names], ['Fix-It']].each do |args|
    it "prints the usage for #{args.inspect}" do
      result = run(*args)

      expect(result.exitstatus).to eq(1)
      expect(result.output).to eq("usage: bin/agent-merge <task-name>\n")
    end
  end

  # See the same example in agent_worktree_spec.rb: from a folder inside
  # the main checkout, git prints the two folders in different forms.
  it 'works from a folder inside the main checkout' do
    work = commit({ 'app.rb' => "1\n" }, chdir: worktree)

    result = run('fix-it', chdir: File.join(repo, 'db'))

    expect(result).to be_success, result.output
    expect(origin_main).to eq(work)
  end
end

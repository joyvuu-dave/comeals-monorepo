# frozen_string_literal: true

require 'rails_helper'

# bin/agent-worktree-done removes a task's worktree and drops its two
# databases, and keeps the branch. It runs here against a throwaway
# repository (spec/support/throwaway_repository.rb); dropdb is a fake.
RSpec.describe 'bin/agent-worktree-done' do
  include ThrowawayRepository

  let(:script) { File.join(ScriptSandbox::REPO, 'bin/agent-worktree-done') }
  let(:worktree) { worktree_path('fix-it') }

  before do
    make_repository
    git('worktree', 'add', '-q', '-b', 'agent/fix-it', worktree, 'main')
    sandbox.fake('dropdb')
  end

  def run(*, chdir: repo) = sandbox.run(script, *, env: git_env, chdir: chdir)

  it 'removes the worktree, drops both databases, keeps the branch, and says how to merge it' do
    commit({ 'app.rb' => "1\n" }, chdir: worktree)
    commit({ 'app.rb' => "2\n" }, chdir: worktree)

    result = run('fix-it')

    expect(result).to be_success, result.output
    expect(File).not_to exist(worktree)
    expect(branches).to include('agent/fix-it')
    expect(sandbox.call_lines).to eq(['dropdb --if-exists comeals_test_fix_it',
                                      'dropdb --if-exists comeals_admin_e2e_fix_it'])
    expect(result.output).to eq(<<~OUT)
      Removed ../comeals-fix-it and dropped comeals_test_fix_it (and comeals_admin_e2e_fix_it if it existed).
      Branch agent/fix-it still has 2 commit(s) that main does not:
        merge it:   git merge agent/fix-it && git branch -d agent/fix-it
        discard it: git branch -D agent/fix-it
    OUT
  end

  it 'says the branch can be deleted when main has all of it' do
    result = run('fix-it')

    expect(result).to be_success, result.output
    expect(result.output).to end_with('Branch agent/fix-it has nothing main lacks; delete it with: ' \
                                      "git branch -d agent/fix-it\n")
  end

  # A worktree that is on another branch: there is no agent/<name> to count.
  it 'counts nothing ahead when there is no branch of that name' do
    git('worktree', 'add', '-q', '-b', 'other-branch', worktree_path('odd'), 'main')

    result = run('odd')

    expect(result).to be_success, result.output
    expect(File).not_to exist(worktree_path('odd'))
    expect(result.output).to include('Branch agent/odd has nothing main lacks')
  end

  it 'refuses, and removes nothing, while the worktree has uncommitted changes' do
    File.write(File.join(worktree, 'new.rb'), "1\n")

    result = run('fix-it')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq(<<~OUT)
      The worktree at ../comeals-fix-it has uncommitted changes:
      ?? new.rb
      Commit them there (or discard them on purpose), then rerun this.
    OUT
    expect(File).to exist(File.join(worktree, 'new.rb'))
    expect(sandbox.calls).to be_empty
  end

  it 'refuses when there is no worktree of that name' do
    result = run('other')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("No worktree at ../comeals-other.\n")
  end

  it 'refuses to run from inside a worktree' do
    result = run('fix-it', chdir: worktree)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("Run this from the main checkout, not from inside a worktree.\n")
    expect(File).to exist(worktree)
  end

  [[], %w[two names], ['Fix-It']].each do |args|
    it "prints the usage for #{args.inspect}" do
      result = run(*args)

      expect(result.exitstatus).to eq(1)
      expect(result.output).to eq("usage: bin/agent-worktree-done <task-name>\n")
    end
  end
end

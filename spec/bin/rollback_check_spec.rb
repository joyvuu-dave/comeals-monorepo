# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/rollback-check, which the Rollback and Deploy workflows run before
# they roll back only the code (#133). It runs in a repository of its own
# here: CI checks out only the newest commit of this one.
RSpec.describe 'bin/rollback-check', bash_coverage: BashCoverage.new('spec/bin/rollback_check_spec.rb') do
  let(:script) { Rails.root.join('bin/rollback-check').to_s }
  let(:repo) { Dir.mktmpdir }

  after { FileUtils.remove_entry(repo) }

  # Holds bin/rollback-check at 100% of its lines (BashCoverage::FILES).
  # It runs only when every example in the file ran, so one example on its
  # own can still pass.
  after(:context) do
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    self.class.metadata[:bash_coverage].check! if ran_all
  end

  def git(*)
    out, status = Open3.capture2e('git', '-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                                  '-c', 'commit.gpgsign=false', *)
    raise out unless status.success?

    out.strip
  end

  # Writes the files and commits them, and returns the commit. A body of
  # nil deletes the file.
  def commit(files)
    files.each do |path, body|
      next File.delete(File.join(repo, path)) if body.nil?

      FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
      File.write(File.join(repo, path), body)
    end
    git('add', '-A')
    git('commit', '-q', '-m', 'files')
    git('rev-parse', 'HEAD')
  end

  # Runs the script in the repository through BashCoverage, which counts
  # its lines, and returns its output (stdout and stderr) and status.
  def check(*)
    Tempfile.create('rollback-check-output') do |output|
      status = self.class.metadata[:bash_coverage].run(
        '-c', 'cd "$1" && out=$2 && shift 2 && exec "$@" > "$out" 2>&1', 'rollback-check', repo, output.path, script, *
      )
      [File.read(output.path), status]
    end
  end

  before { git('init', '-q') }

  it 'lists the migrations added since the commit to go back to, and fails' do
    old = commit('db/migrate/20260101000000_first.rb' => '', 'app/a.rb' => '')
    commit('db/migrate/20260201000000_second.rb' => '', 'app/b.rb' => '')
    now = commit('db/migrate/20260301000000_third.rb' => '')

    out, status = check(old, now)

    expect(status.exitstatus).to eq(1)
    expect(out.lines.map(&:strip).drop(1))
      .to eq(%w[db/migrate/20260201000000_second.rb db/migrate/20260301000000_third.rb])
  end

  it 'passes when only other files changed' do
    old = commit('db/migrate/20260101000000_first.rb' => '')
    now = commit('app/a.rb' => 'changed')

    out, status = check(old, now)

    expect(status.exitstatus).to eq(0)
    expect(out).to include('No migration was added after')
  end

  # An edit to a migration that both commits have is not a new one: the
  # database already ran it.
  it 'passes when a migration both commits have was only edited' do
    old = commit('db/migrate/20260101000000_first.rb' => '')
    now = commit('db/migrate/20260101000000_first.rb' => '# a comment')

    _, status = check(old, now)

    expect(status.exitstatus).to eq(0)
  end

  # After a deploy, the migrations production ran are deleted
  # (AGENTS.md). The database keeps what they made, so the older code
  # still runs on it.
  it 'passes when migrations were only deleted' do
    old = commit('db/migrate/20260101000000_first.rb' => 'class First; end', 'app/a.rb' => '')
    now = commit('db/migrate/20260101000000_first.rb' => nil)

    out, status = check(old, now)

    expect(status.exitstatus).to eq(0)
    expect(out).to include('No migration was added after')
  end

  # git calls a deleted file and an added file with nearly the same text a
  # rename. The added file is still a new migration that ran.
  it 'lists a new migration added in the same commit that deletes one with nearly the same text' do
    body = "class Change < ActiveRecord::Migration[8.1]\n  def change\n    add_column :meals, :a, :text\n  end\nend\n"
    old = commit('db/migrate/20260101000000_change.rb' => body)
    now = commit('db/migrate/20260101000000_change.rb' => nil,
                 'db/migrate/20260301000000_change.rb' => body.sub(':a', ':b'))

    out, status = check(old, now)

    expect(status.exitstatus).to eq(1)
    expect(out.lines.map(&:strip).drop(1)).to eq(%w[db/migrate/20260301000000_change.rb])
  end

  it 'refuses to run without two commits' do
    out, status = check('only-one')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/rollback-check')
  end
end

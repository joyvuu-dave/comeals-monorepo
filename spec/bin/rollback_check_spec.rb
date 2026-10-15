# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/rollback-check, which the Rollback and Deploy workflows run before
# they roll back only the code (#133). It runs in a repository of its own
# here: CI checks out only the newest commit of this one.
RSpec.describe 'bin/rollback-check' do
  let(:script) { Rails.root.join('bin/rollback-check').to_s }
  let(:repo) { Dir.mktmpdir }

  after { FileUtils.remove_entry(repo) }

  def git(*)
    out, status = Open3.capture2e('git', '-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                                  '-c', 'commit.gpgsign=false', *)
    raise out unless status.success?

    out.strip
  end

  # Writes the files and commits them, and returns the commit.
  def commit(files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
      File.write(File.join(repo, path), body)
    end
    git('add', '-A')
    git('commit', '-q', '-m', 'files')
    git('rev-parse', 'HEAD')
  end

  def check(*)
    Open3.capture2e(script, *, chdir: repo)
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

  it 'refuses to run without two commits' do
    out, status = check('only-one')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/rollback-check')
  end
end

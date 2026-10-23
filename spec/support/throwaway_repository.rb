# frozen_string_literal: true

# For the specs of bin/agent-worktree, bin/agent-worktree-done and
# bin/agent-merge, which change real git state. They run only against a
# repository made here: a bare "origin" and a clone named
# comeals-monorepo, both inside a ScriptSandbox, with a git config of
# their own (no user hooks, no signing) and real git on the PATH.
module ThrowawayRepository
  # A file to commit as a symlink to the real script at this path in the
  # repository, so a script that runs another by its path runs the real one.
  RealScript = Struct.new(:path)

  def self.included(base)
    base.include_context 'with a script sandbox'
    base.let(:sandbox) { new_sandbox(real: %w[git], root_name: 'comeals-monorepo') }
    base.let(:repo) { sandbox.root }
    base.let(:origin) { File.join(sandbox.dir, 'origin.git') }
  end

  def git_env
    { 'GIT_CONFIG_NOSYSTEM' => '1' }
  end

  def make_repository(files = { 'README.md' => "Comeals\n" })
    File.write(File.join(sandbox.dir, 'home', '.gitconfig'), <<~CONFIG)
      [user]
        name = Test
        email = test@example.com
      [commit]
        gpgsign = false
      [init]
        defaultBranch = main
      [advice]
        detachedHead = false
    CONFIG
    git('init', '-q', '--bare', origin, chdir: sandbox.dir)
    git('init', '-q')
    git('remote', 'add', 'origin', origin)
    commit(files)
    git('push', '-q', '-u', 'origin', 'main')
  end

  # Runs real git in the throwaway repository (or chdir), as the scripts
  # would, and returns its output.
  def git(*args, chdir: repo)
    out, status = Open3.capture2e(sandbox_git_env, 'git', *args, chdir: chdir, unsetenv_others: true)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  # Writes the files, commits them, and returns the commit.
  def commit(files, chdir: repo, message: 'files')
    files.each do |path, body|
      target = File.join(chdir, path)
      next File.delete(target) if body.nil?

      FileUtils.mkdir_p(File.dirname(target))
      if body.is_a?(RealScript)
        File.symlink(File.join(ScriptSandbox::REPO, body.path), target)
      else
        File.write(target, body)
      end
    end
    git('add', '-A', chdir: chdir)
    git('commit', '-q', '-m', message, chdir: chdir)
    git('rev-parse', 'HEAD', chdir: chdir)
  end

  def branches = git('branch', '--format=%(refname:short)').lines.map(&:strip)

  def worktree_path(name) = File.join(sandbox.dir, "comeals-#{name}")

  private

  def sandbox_git_env
    { 'PATH' => ENV.fetch('PATH'), 'HOME' => File.join(sandbox.dir, 'home'), 'GIT_CONFIG_NOSYSTEM' => '1' }
  end
end

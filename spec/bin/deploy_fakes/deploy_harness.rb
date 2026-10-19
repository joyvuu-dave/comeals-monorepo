# frozen_string_literal: true

require 'bashcov'
require 'bashcov/runner'
require 'fileutils'
require 'pty'
require 'tmpdir'

# Runs the real bin/deploy against fake outside commands, in a throwaway
# git repository, under bashcov. spec/bin/deploy_spec.rb is its only user.
#
# The script's PATH holds two folders and nothing else: one with the fakes
# (spec/bin/deploy_fakes/fake_command.bash, once per command name) and one
# with links to the few local tools the script needs (awk, grep, python3
# and so on). So the real heroku, gh, curl, npm or bundle cannot run: they
# are not on the PATH, and the fake git refuses every remote it was not
# told about.
class DeployHarness
  ROOT = File.expand_path('../../..', __dir__)
  SCRIPT = File.join(ROOT, 'bin/deploy')
  FAKE = File.join(__dir__, 'fake_command.bash')
  FAKE_NAMES = %w[heroku git gh curl bundle npm sleep].freeze
  # The local tools bin/deploy (and the fakes) run. None talks to another
  # machine.
  LOCAL_TOOLS = %w[awk cat date dirname grep head python3 tail].freeze
  RULE_OPTIONS = %i[stdout stderr exit times].freeze

  Result = Struct.new(:output, :status)

  attr_reader :dir, :repo, :commits

  # `coverage` (a BashCoverage) collects the lines each run covers.
  def initialize(coverage)
    @coverage = coverage
    @dir = File.realpath(Dir.mktmpdir('deploy-spec'))
    @repo = File.join(@dir, 'repo')
    @rules = []
    @scenario = { check_runs: "test|completed|success\nlint|completed|skipped\n", logs: '' }
    @state = {
      maintenance: 'off', web: 1, backups: 0, releases: [], pushed: '', heroku_sha: '',
      config: { 'RAILS_DB_POOL' => '4', 'SOLID_QUEUE_IN_PUMA' => 'true' }
    }
    build_path
    build_repo
  end

  def cleanup = FileUtils.remove_entry(@dir)

  def fake_home = File.join(@dir, 'fake')

  # --- Setting up the scenario --------------------------------------------

  # Answers the next call(s) of `cmd` whose arguments match `match`.
  # Options: stdout:, stderr:, exit:, times:, exec: (see fake_command.bash).
  # `match` is a bash regular expression (ERE) on the arguments joined by
  # spaces.
  def rule(cmd, match, **options)
    @rules << { cmd:, match: }.merge(options)
  end

  # logs: what `heroku logs` prints; check_runs: what `gh api` prints.
  def set(**values) = @scenario.merge!(values)

  # The fake production app before the run: maintenance ('on' or 'off'),
  # web, backups, releases (the statuses `heroku releases` answers, one per
  # call, then 'succeeded'), heroku_sha (what `git ls-remote heroku`
  # answers; '' for nothing) and config.
  def production(**values) = @state.merge!(values)

  def git(*)
    # No GIT_DIR and the like from the outside: a git hook that runs RSpec
    # would point every command here at the real repository.
    env = { 'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil }
    out, status = Open3.capture2e(env, real_git, '-C', @repo, '-c', 'user.name=Test',
                                  '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', *)
    raise out unless status.success?

    out.strip
  end

  def commit(files, message = 'change')
    files.each do |path, body|
      FileUtils.mkdir_p(File.join(@repo, File.dirname(path)))
      File.write(File.join(@repo, path), body)
    end
    git('add', '-A')
    git('commit', '-q', '-m', message)
    git('rev-parse', 'HEAD')
  end

  # A commit that exists only in another repository, the way a commit
  # Heroku has can be missing here. Returns the commit and that folder.
  def commit_elsewhere(files)
    side = File.join(@dir, 'side')
    git('clone', '-q', @repo, side)
    files.each { |path, body| File.write(File.join(side, path), body) }
    git('-C', side, 'add', '-A')
    git('-C', side, 'commit', '-q', '-m', 'elsewhere')
    [git('-C', side, 'rev-parse', 'HEAD'), side]
  end

  def real_git = @real_git ||= which('git')

  # bashcov needs bash 4.1 or newer (BASH_XTRACEFD). macOS ships 3.2 as
  # /bin/bash, so look on the PATH first.
  def bash
    @bash ||= begin
      candidates = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { File.join(it, 'bash') } + ['/bin/bash']
      found = candidates.find do |path|
        File.executable?(path) && IO.popen([path, '-c', 'echo ${BASH_VERSINFO[0]}'], &:read).to_i >= 4
      end
      found || raise('spec/bin/deploy_spec.rb needs bash 4 or newer on the PATH (macOS: brew install bash)')
    end
  end

  # --- Running ------------------------------------------------------------

  # Runs bin/deploy with `args`. `input` is what the person types; with
  # `tty: true` it is typed on a terminal, so `[ -t 0 ]` is true.
  def run(*args, input: '', tty: false, env: {})
    write_fake_home
    output_path = File.join(@dir, 'output')

    with_stdin(input, tty) do |stdin_path|
      wrapper = write_wrapper(stdin_path, output_path, env)
      # skip_uncovered: without it bashcov walks the whole repository
      # (node_modules too) for scripts that did not run.
      Bashcov.skip_uncovered = true
      Bashcov.bash_path = bash
      runner = Bashcov::Runner.new([bash, wrapper, *args])
      status = runner.run
      @coverage.add(runner.result)
      output = File.read(output_path).gsub(/\e\[[0-9;]*m/, '')
      refuse_outside_commands(output)
      Result.new(output, status.exitstatus)
    end
  end

  # The fake production app after the run.
  def state
    dir = File.join(fake_home, 'state')
    read = ->(name) { File.read(File.join(dir, name)).strip }
    {
      maintenance: read['maintenance'] == 'on', web: Integer(read['web']), backups: Integer(read['backups']),
      pushed: read['pushed'].then { it.empty? ? nil : it },
      config: Dir.children(File.join(dir, 'config')).sort.index_with { read["config/#{it}"] }
    }
  end

  # Every call to a fake, in order, as one string each ("heroku
  # maintenance:on -a comeals-monorepo"). git commands that ran the real
  # git on the throwaway repository are not recorded.
  def calls
    dir = File.join(fake_home, 'calls')
    Dir.children(dir).sort.map { |name| File.read(File.join(dir, name)).split("\0").join(' ') }
  end

  def calls_to(name) = calls.select { |call| call.start_with?("#{name} ") || call == name }

  def unexpected
    path = File.join(fake_home, 'unexpected')
    File.exist?(path) ? File.read(path) : ''
  end

  # Takes a fake off the PATH, as if that command were not installed.
  def uninstall(name) = File.delete(File.join(@dir, 'fake-bin', name))

  private

  def write_fake_home
    FileUtils.mkdir_p(%w[calls rules state/config].map { |sub| File.join(fake_home, sub) })
    files = rule_files.merge(
      'count' => '0', 'real_git' => real_git, 'logs' => @scenario[:logs], 'check_runs' => @scenario[:check_runs],
      'state/maintenance' => @state[:maintenance], 'state/web' => @state[:web].to_s,
      'state/backups' => @state[:backups].to_s, 'state/releases' => @state[:releases].map { "#{it}\n" }.join,
      'state/pushed' => @state[:pushed], 'state/heroku_sha' => @state[:heroku_sha]
    )
    @state[:config].each { |var, value| files["state/config/#{var}"] = value }
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(fake_home, path)))
      File.write(File.join(fake_home, path), body)
    end
  end

  def rule_files
    @rules.each.with_index.with_object({}) do |(rule, index), files|
      prefix = format('rules/%03d/', index)
      files["#{prefix}cmd"] = rule[:cmd]
      files["#{prefix}match"] = rule[:match]
      RULE_OPTIONS.each { |key| files["#{prefix}#{key}"] = rule[key].to_s if rule.key?(key) }
      files["#{prefix}exec"] = rule[:exec].map { "#{it}\0" }.join if rule[:exec]
    end
  end

  def which(name)
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { File.join(it, name) }
       .find { |path| File.executable?(path) && !File.directory?(path) } || raise("#{name} is not on the PATH")
  end

  # A fake that got a call it has no answer for, or a command that is not
  # on the PATH at all, fails the example: the real one might have run.
  def refuse_outside_commands(output)
    raise "bin/deploy ran a command the fakes do not answer:\n#{unexpected}" unless unexpected.empty?
    raise "bin/deploy ran a command that is not on the fake PATH:\n#{output}" if output.include?('command not found')
  end

  def build_path
    fake_bin = File.join(@dir, 'fake-bin')
    tools = File.join(@dir, 'tools')
    FileUtils.mkdir_p([fake_bin, tools])
    body = "#!#{bash}\n#{File.read(FAKE)}"
    (FAKE_NAMES + ['smoke']).each do |name|
      path = File.join(fake_bin, name)
      File.write(path, body)
      File.chmod(0o755, path)
    end
    LOCAL_TOOLS.each { |name| File.symlink(which(name), File.join(tools, name)) }
    File.symlink(bash, File.join(tools, 'bash'))
    @path = [fake_bin, tools].join(File::PATH_SEPARATOR)
  end

  # Three commits: the oldest adds a migration, the next adds a second
  # one, and HEAD changes only app code. bin/smoke is the fake.
  def build_repo
    FileUtils.mkdir_p(File.join(@repo, 'bin'))
    git('init', '-q', '-b', 'main')
    File.symlink(File.join(@dir, 'fake-bin', 'smoke'), File.join(@repo, 'bin', 'smoke'))
    @commits = {}
    @commits[:first_migration] = commit({ 'db/migrate/20260101000000_first.rb' => '', 'app/a.rb' => '1' }, 'first')
    @commits[:second_migration] = commit({ 'db/migrate/20260201000000_second.rb' => '' }, 'second')
    @commits[:head] = commit({ 'app/a.rb' => '2' }, 'only app code')
    git('remote', 'add', 'origin', 'https://github.com/example/comeals.git')
    git('remote', 'add', 'heroku', 'https://git.heroku.com/comeals-monorepo.git')
    git('update-ref', 'refs/remotes/origin/main', @commits[:head])
    @state[:heroku_sha] = @commits[:second_migration]
    git('status', '--porcelain').empty? || raise('the throwaway repository should be clean')
  end

  def with_stdin(input, tty)
    if tty
      PTY.open do |master, slave|
        master.write(input)
        yield slave.path
      end
    else
      path = File.join(@dir, 'stdin')
      File.write(path, input)
      yield path
    end
  end

  # bashcov starts bash with xtrace on and with PS4, BASH_XTRACEFD and
  # SHELLOPTS in the environment. This wrapper keeps those three, drops
  # everything else the spec process has (bundler's RUBYOPT, its PATH),
  # and runs bin/deploy from the throwaway repository.
  def write_wrapper(stdin_path, output_path, env)
    vars = {
      'PATH' => @path, 'HOME' => File.join(@dir, 'home'), 'FAKE_HOME' => fake_home,
      'GIT_CONFIG_NOSYSTEM' => '1', 'TERM' => 'dumb'
    }.merge(env)
    FileUtils.mkdir_p(vars['HOME'])
    path = File.join(@dir, 'wrapper.sh')
    File.write(path, <<~BASH)
      exec <#{stdin_path.shellescape} >#{output_path.shellescape} 2>&1
      cd #{@repo.shellescape}
      exec /usr/bin/env -i #{vars.map { |k, v| "#{k}=#{v.shellescape}" }.join(' ')} \\
        SHELLOPTS="$SHELLOPTS" PS4="$PS4" BASH_XTRACEFD="$BASH_XTRACEFD" \\
        #{bash.shellescape} #{SCRIPT.shellescape} "$@"
    BASH
    path
  end
end

# frozen_string_literal: true

require 'digest'
require 'open3'
require 'shellwords'
require 'tmpdir'

# Runs a script from bin/ with every outside command replaced by a fake.
#
# The sandbox is a temporary folder with:
#
#   root/     a stand-in for the repository. A script that does
#             `cd "$(dirname "$0")/.."` is run through a symlink at
#             root/bin/<name>, so it works on the files here, never on the
#             real checkout. The bash coverage check resolves the symlink,
#             so the lines it counts are the real script's.
#   fakebin/  the fakes, first on the PATH. Each one writes its name, the
#             folder it ran in, the environment variables it was asked to
#             note, and its arguments to a log, then does what its body
#             says (by default, nothing, with exit 0). Every fake is a link
#             to one shared script, which reads the body from the sandbox:
#             a Mac checks each new program file the first time it runs,
#             which takes about 0.2 seconds, and a run of bin/check calls
#             about 60 fakes.
#   safebin/  links to the few real programs a script may run: bash, sed,
#             grep, awk and the like, which only read and write files. The
#             PATH has nothing else on it.
#
# A command that is in neither folder is not found. Bash then calls the
# exported command_not_found_handle below, which writes the name to a log;
# #unknown_commands reads it, and every spec that uses a sandbox checks it is
# empty. So a script cannot run a real outside command, and a spec fails if
# it tries.
#
# When the sandbox is given a BashCoverage (spec/support/bash_coverage.rb),
# every run goes through it, so the script's lines are counted.
class ScriptSandbox
  REPO = File.expand_path('../..', __dir__)

  # The real programs a script may run. Each one only reads its input or
  # writes inside the sandbox. `rm`, `sleep`, `kill`-like tools, network
  # tools and every project tool are fakes instead.
  SAFE = %w[
    bash sh env cat sed grep awk head tail sort comm cut tr wc cp mv mkdir dirname basename seq find ls
    cksum date uniq tee touch chmod readlink xargs true false printf test expr ln
  ].freeze

  Call = Struct.new(:name, :pwd, :env, :args) do
    def line = [name, *args].join(' ')
  end

  Result = Struct.new(:output, :status) do
    delegate :exitstatus, to: :status
    delegate :success?, to: :status
  end

  attr_reader :dir, :root, :fakebin

  # real: programs to add to safebin besides SAFE, such as git for a spec
  # that works on a throwaway repository. root_name: the name of the
  # stand-in repository's folder. coverage: the spec file's BashCoverage.
  def initialize(real: [], root_name: 'root', coverage: nil)
    @coverage = coverage
    @dir = File.realpath(Dir.mktmpdir('script-sandbox'))
    @root = File.join(@dir, root_name)
    @fakebin = File.join(@dir, 'fakebin')
    @safebin = File.join(@dir, 'safebin')
    @outputs = 0
    # root/tmp: the repository keeps an empty tmp/ (tmp/.keep).
    [File.join(@root, 'tmp'), @fakebin, @safebin, File.join(@dir, 'home'), File.join(@dir, 'tmp')]
      .each { |d| FileUtils.mkdir_p(d) }
    link_safe_programs(SAFE)
    link_untraced_programs(real)
    fake_rm
    fake_mktemp
  end

  def bash = @bash ||= which('bash')

  # The shared fake (see fakebin above).
  def dispatcher = shared_file('fake', dispatcher_source)

  # A file that every sandbox links to, written once. Its folder is named
  # after its text, so two runs at once never write different text to it.
  def shared_file(name, source)
    path = File.join(Dir.tmpdir, "comeals-script-sandbox-#{Digest::SHA256.hexdigest(source)[0, 16]}", name)
    return path if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    partial = "#{path}.#{Process.pid}"
    File.write(partial, source)
    File.chmod(0o755, partial)
    File.rename(partial, path)
    path
  end

  # The absolute path of a real program, for a fake that must really wait
  # (a server that stays up until it is stopped).
  def real(program) = which(program)

  # Links root/<path> to the real file in the repository.
  def link(path)
    target = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.symlink(File.join(REPO, path), target)
    target
  end

  def write(path, content = '', executable: false)
    target = path.start_with?('/') ? path : File.join(root, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
    File.chmod(0o755, target) if executable
    target
  end

  # A fake command on the PATH. The body is bash; "$@" are its arguments.
  # notes: environment variables to write to the log with each call.
  def fake(name, body = '', notes: [])
    install_fake(File.join(fakebin, name), name, body, notes)
  end

  # A fake at a path inside root, for a script that runs another one by its
  # path (bin/tapioca, tests/admin/server.sh). It logs like a command, under
  # the path it was run by.
  def fake_script(path, body = '', notes: [])
    install_fake(File.join(root, path), path, body, notes)
  end

  # Bash that prints text exactly, whatever characters it holds.
  def says(text)
    @outputs += 1
    file = File.join(dir, 'outputs', @outputs.to_s)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
    "cat #{file.shellescape}"
  end

  # Bash for a fake that answers by its arguments. Each key is matched
  # against the arguments joined by spaces, with * standing for any text;
  # each value is bash to run. Arguments that match no key run `otherwise`.
  def answers(cases, otherwise: 'exit 0')
    arms = cases.map do |pattern, action|
      glob = pattern.split('*', -1).map { |part| part.empty? ? '' : "'#{part.gsub("'", "'\\''")}'" }.join('*')
      "  #{glob}) #{action} ;;"
    end
    "case \"$*\" in\n#{arms.join("\n")}\n  *) #{otherwise} ;;\nesac"
  end

  # Runs the command in chdir with only the sandbox's environment (and
  # env), and returns its output, standard and error together.
  def run(command, *, env: {}, chdir: root, input: nil)
    return run_measured(command, *, env: env, chdir: chdir, input: input) if @coverage

    output, status = Open3.capture2e(base_env.merge(env), command, *,
                                     chdir: chdir, unsetenv_others: true, stdin_data: input.to_s)
    Result.new(output, status)
  end

  def calls
    log = File.join(dir, 'calls.log')
    return [] unless File.exist?(log)

    File.read(log).split("\x1e").map do |record|
      name, pwd, env, *args = record.split("\x1f", -1)
      Call.new(name, pwd, env.split("\x1d").to_h { |pair| pair.split('=', 2) }, args)
    end
  end

  def calls_to(name) = calls.select { |call| call.name == name }

  def call_lines = calls.map(&:line)

  def unknown_commands
    log = File.join(dir, 'unknown.log')
    File.exist?(log) ? File.read(log).lines.map(&:chomp) : []
  end

  def cleanup
    FileUtils.remove_entry(dir)
  end

  private

  # BashCoverage#run starts bash with the trace settings and the suite's
  # environment. This wrapper, run by that bash, moves to chdir, clears
  # the environment but for the sandbox's and the trace settings, and
  # sends the output to a file.
  def run_measured(command, *args, env:, chdir:, input:)
    @measured_runs = (@measured_runs || 0) + 1
    base = File.join(dir, 'measured', @measured_runs.to_s)
    write("#{base}.in", input.to_s)
    pairs = base_env.merge(env).compact.map { |name, value| "#{name}=#{value}".shellescape }
    write("#{base}.sh", <<~BASH)
      cd #{chdir.shellescape} || exit 99
      exec env -i #{pairs.join(' ')} SHELLOPTS="$SHELLOPTS" PS4="$PS4" BASH_XTRACEFD="$BASH_XTRACEFD" \
        #{[command, *args].map(&:shellescape).join(' ')} <#{"#{base}.in".shellescape} >#{"#{base}.out".shellescape} 2>&1
    BASH
    status = @coverage.run("#{base}.sh")
    Result.new(File.read("#{base}.out"), status)
  end

  def which(program)
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |d| File.join(d, program) }
       .find { |path| File.file?(path) && File.executable?(path) }
  end

  def link_safe_programs(programs)
    programs.each do |program|
      path = which(program)
      File.symlink(path, File.join(@safebin, program)) if path
    end
  end

  # A real program that is not a script of ours, such as git, runs without
  # bashcov's trace settings. Git runs its helpers through /bin/sh, which on
  # a Mac is bash 3.2; that bash cannot send the trace to bashcov, so it
  # prints it to the error output instead, into what the spec reads. The
  # wrapper is bash 5, for the same reason.
  def link_untraced_programs(programs)
    programs.each do |program|
      source = "#!#{bash}\nset +x\nexec env -u SHELLOPTS -u PS4 -u BASH_XTRACEFD #{which(program).shellescape} \"$@\"\n"
      File.symlink(shared_file("#{program}-untraced", source), File.join(@safebin, program))
    end
  end

  # Deletes only inside the sandbox, and logs every call like any fake.
  def fake_rm
    fake('rm', <<~BASH)
      for arg in "$@"; do
        case "$arg" in -*) continue ;; esac
        case "$(cd "$(dirname "$arg")" 2>/dev/null && pwd -P)/" in
          #{dir.shellescape}/*) ;;
          *) echo "sandbox: rm outside the sandbox: $arg" >&2; exit 1 ;;
        esac
      done
      #{which('rm').shellescape} "$@"
    BASH
  end

  # The real mktemp on a Mac ignores TMPDIR, so this one names the
  # sandbox's tmp folder itself. -t PREFIX is the only option the scripts
  # use.
  def fake_mktemp
    fake('mktemp', <<~BASH)
      prefix=tmp
      [ "${1:-}" = "-t" ] && prefix="$2"
      exec #{which('mktemp').shellescape} "$TMPDIR/$prefix.XXXXXX"
    BASH
  end

  def install_fake(path, name, body, notes)
    key = name.tr('/', '%')
    write(File.join(dir, 'bodies', key), "#{body}\n")
    write(File.join(dir, 'notes', key), notes.map { |note| "#{note}\n" }.join)
    FileUtils.mkdir_p(File.dirname(path))
    File.symlink(dispatcher, path) unless File.symlink?(path)
    path
  end

  def dispatcher_source
    <<~BASH
      #!#{bash}
      # The one fake command of ScriptSandbox (spec/support/script_sandbox.rb).
      # Every fake is a link to this file. It logs the call, then runs the
      # body the sandbox wrote for the name it was run by. It is not traced:
      # it is not one of the scripts measured.
      set +x
      name=$0
      name=${name#"$SANDBOX_FAKEBIN"/}
      name=${name#"$SANDBOX_ROOT"/}
      key=${name////%}
      # One write for the whole record, so that the records of fakes that
      # run at the same time (a server in the background) cannot mix.
      record="$name"$'\037'"$PWD"$'\037'
      first=1
      while IFS= read -r note; do
        if [ -n "${!note+set}" ]; then
          [ "$first" = 1 ] || record+=$'\035'
          record+="$note=${!note}"
          first=0
        fi
      done < "$SANDBOX_DIR/notes/$key"
      for arg in "$@"; do record+=$'\037'"$arg"; done
      printf '%s\036' "$record" >> "$SANDBOX_DIR/calls.log"
      sandbox_body="$SANDBOX_DIR/bodies/$key"
      unset name key first note record arg
      # shellcheck disable=SC1090
      source "$sandbox_body"
    BASH
  end

  def base_env
    {
      'PATH' => "#{fakebin}:#{@safebin}",
      'HOME' => File.join(dir, 'home'),
      'TMPDIR' => File.join(dir, 'tmp'),
      'LANG' => 'en_US.UTF-8',
      'SANDBOX_DIR' => dir,
      'SANDBOX_FAKEBIN' => fakebin,
      'SANDBOX_ROOT' => root,
      'SANDBOX_UNKNOWN' => File.join(dir, 'unknown.log'),
      'BASH_FUNC_command_not_found_handle%%' =>
        '() { printf "%s\n" "$*" >> "$SANDBOX_UNKNOWN"; echo "sandbox: no fake for $1" >&2; return 127; }'
    }
  end
end

# A sandbox for each example, removed after it, and a check that the
# script ran no command that has no fake.
#
# A spec file that names a BashCoverage in its metadata
# (RSpec.describe 'bin/x', bash_coverage: BashCoverage.new(<this file>))
# runs every script through it, and after its last example checks that the
# scripts BashCoverage::FILES gives it ran every line. The check runs only
# when every example of the file ran, so one example on its own can pass.
RSpec.shared_context 'with a script sandbox' do
  let(:sandbox) { new_sandbox }

  def new_sandbox(**)
    ScriptSandbox.new(coverage: self.class.metadata[:bash_coverage], **)
  end

  after do
    raise "commands with no fake: #{sandbox.unknown_commands}" unless sandbox.unknown_commands.empty?

    sandbox.cleanup
  end

  after(:context) do
    coverage = self.class.metadata[:bash_coverage]
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    coverage.check! if coverage && ran_all
  end
end

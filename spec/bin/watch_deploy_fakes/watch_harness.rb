# frozen_string_literal: true

require 'json'
require 'pty'
require 'rbconfig'

# Runs the real bin/watch-deploy with fake heroku and curl commands
# (ScriptSandbox) and a fast clock (spec/bin/preload/fake_clock.rb).
#
# The fakes take their answers in order: `answers` gives one kind of call its
# list, each call uses the next one, and the last one repeats. An answer can
# print (out, err), fail (exit) or never end (hang).
class WatchHarness
  # 7:00 am Central on a day with daylight saving time.
  START = '2026-10-30T12:00:00Z'
  START_TIME = Time.iso8601(START)
  SCRIPT = File.expand_path('../../../bin/watch-deploy', __dir__)
  PRELOAD = File.expand_path('../preload', __dir__)
  COMMIT = 'c28c3052aaaabbbbccccdddd'
  REPORT = 'tmp/deploy/watch-20261030T120000Z.txt'

  Result = Struct.new(:output, :status)

  RELEASES = [
    { version: 619, status: 'succeeded', description: "Deploy #{COMMIT[0, 8]}", created_at: '2026-10-30T11:55:00Z' },
    { version: 618, status: 'succeeded', description: 'Deploy aaaa1111', created_at: '2026-10-20T11:55:00Z' }
  ].freeze
  BACKUPS = <<~TEXT
    === Backups

      ID     Created at                  Status                                Size     Database
    ────────────────────────────────────────────────────────────────────────────────
      a250   2026-10-30 11:58:00 +0000   Completed 2026-10-30 11:59:00 +0000   3.26MB   SILVER
      b245   2026-10-30 11:50:12 +0000   Completed 2026-10-30 11:50:14 +0000   3.26MB   SILVER
      a249   2026-10-29 01:09:44 +0000   Completed 2026-10-29 01:12:17 +0000   3.26MB   SILVER
  TEXT

  attr_reader :sandbox

  def initialize(sandbox, speed: 60)
    @sandbox = sandbox
    @speed = speed
    @real_sleep = sandbox.real('sleep')
    install_fakes
    healthy
  end

  def self.log_line(seconds, source, text)
    "#{(START_TIME + seconds).utc.iso8601(6).sub('Z', '+00:00')} #{source}: #{text}\n"
  end

  def self.router(seconds, path: '/', status: 200, extra: 'at=info')
    log_line(seconds, 'heroku[router]',
             %(#{extra} method=GET path="#{path}" host=comeals.com request_id=1 fwd="1.2.3.4" ) +
               %(dyno=web.1 connect=0ms service=5ms status=#{status} bytes=100 protocol=https))
  end

  # A line from before the watch: what a real stream starts with. Without one,
  # the scan would say that lines were lost.
  OLD_LINE = log_line(-3600, 'app[web.1]', 'I, [x #1]  INFO -- : an older line')
  LINES = [OLD_LINE, router(5, path: '/api/v1/communities'),
           log_line(6, 'heroku[web.1]',
                    'source=web.1 dyno=heroku.1 sample#memory_total=212.46MB sample#memory_rss=1MB ' \
                    'sample#memory_quota=512.00MB'),
           log_line(7, 'heroku[worker.1]',
                    'source=worker.1 dyno=heroku.2 sample#memory_total=241.10MB sample#memory_rss=1MB ' \
                    'sample#memory_quota=512.00MB'),
           router(8)].join.freeze

  def healthy
    answers(:releases, out: RELEASES.to_json)
    answers(:commit, out: "#{COMMIT}\n")
    answers(:maintenance, out: "off\n")
    answers(:ps, out: dynos.to_json)
    answers(:psql, out: database)
    answers(:backups, out: BACKUPS)
    answers(:tail, out: LINES, hang: true)
    answers(:logs, out: LINES)
    answers(:site, out: '200')
    answers(:version, out: '200')
    answers(:organizations, out: [{ id: 'org1' }].to_json)
    answers(:projects, out: [{ id: 'other', slug: 'x' }, { id: 'proj1', slug: 'comeals' }].to_json)
    answers(:errors, out: '[]')
  end

  def dynos(updated_at: '2026-10-30T11:58:00Z', state: 'up', version: 619)
    [{ name: 'web.1', type: 'web', state:, updated_at:, release: { version: } },
     { name: 'worker.1', type: 'worker', state: 'up', updated_at:, release: { version: } },
     { name: 'run.1234', type: 'run', state: 'up', updated_at:, release: { version: } }]
  end

  def database(**facts)
    # Solid Queue saves the supervisor's kind with its mode.
    defaults = { heartbeats: { 'Supervisor(async)' => 18, 'Dispatcher' => 5, 'Worker' => 7, 'Scheduler' => 9 },
                 failed_new: 0, failed_old: 0,
                 ledger: "#{(START_TIME - 180).to_i}|4|0|", jobs: [], failed_first: nil }
    facts = defaults.merge(facts)
    lines = ['        line        ', '--------------------']
    lines += facts[:heartbeats].map { |kind, age| " heartbeat=#{kind}|#{age}" }
    lines += [" failed_new=#{facts[:failed_new]}", " failed_old=#{facts[:failed_old]}"]
    lines << " failed_first=#{facts[:failed_first]}" if facts[:failed_first]
    lines << " ledger=#{facts[:ledger]}" if facts[:ledger]
    lines += facts[:jobs].map { |job| " job=#{job}" }
    lines += [' end=ok', '(9 rows)', '']
    "#{lines.join("\n")}\n"
  end

  # Replaces the answers to one kind of call. Takes one answer or a list.
  def answers(kind, *list, **one)
    dir = File.join(sandbox.dir, 'answers', kind.to_s)
    FileUtils.remove_dir(dir, true)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'count'), '0')
    (list.empty? ? [one] : list).each_with_index do |answer, index|
      place = File.join(dir, index.to_s)
      FileUtils.mkdir_p(place)
      File.write(File.join(place, 'out'), answer.fetch(:out, ''))
      File.write(File.join(place, 'err'), answer.fetch(:err, ''))
      File.write(File.join(place, 'code'), answer.fetch(:exit, 0).to_s)
      File.write(File.join(place, 'hang'), '') if answer[:hang]
    end
  end

  def write_env(text) = sandbox.write('.env', text)

  def run(*, env: {})
    sandbox.run(RbConfig.ruby, SCRIPT, *, env: env(env))
  end

  # Runs the script with `signal` sent after some real time, as Ctrl-C does.
  def run_and_signal(*, after:, signal: 'INT')
    output = File.join(sandbox.dir, 'signal-output')
    pid = Process.spawn(sandbox.send(:base_env).merge(env({})), RbConfig.ruby, SCRIPT, *,
                        chdir: sandbox.root, unsetenv_others: true, out: output, err: %i[child out])
    Kernel.sleep(after)
    Process.kill(signal, pid)
    Process.wait(pid)
    Result.new(File.read(output), $CHILD_STATUS)
  end

  # Runs the script on a terminal, which is what makes it draw the bar.
  def run_on_terminal(*, env: {})
    full = sandbox.send(:base_env).merge(env(env))
    PTY.spawn(full, RbConfig.ruby, SCRIPT, *, chdir: sandbox.root, unsetenv_others: true) do |reader, _writer, pid|
      text = +''
      begin
        reader.each_char { |char| text << char }
      rescue Errno::EIO
        nil # a terminal says this when the other side has ended
      end
      Process.wait(pid)
      return Result.new(text, $CHILD_STATUS)
    end
  end

  def report = File.read(File.join(sandbox.root, REPORT))

  # The calls of one fake, as lines. These fakes keep their own log, one file
  # per call: two fakes can run at the same moment, and the SQL of a database
  # read is long enough that ScriptSandbox's shared log can mix two records.
  def calls_of(name)
    Dir.glob(File.join(sandbox.dir, 'watch-calls', name, '*')).map { |file| "#{name} #{File.read(file).chomp}" }
  end

  def heroku_calls = calls_of('heroku')

  def curl_calls = calls_of('curl')

  private

  def env(extra)
    rubyopt = %w[child_coverage fake_clock].map { |name| "-r#{File.join(PRELOAD, name)}" }.join(' ')
    { 'RUBYOPT' => rubyopt, 'CHILD_COVERAGE_DIR' => ENV.fetch('CHILD_COVERAGE_DIR', nil), 'FAKE_CLOCK_START' => START,
      'FAKE_CLOCK_SPEED' => @speed.to_s }.merge(extra).compact
  end

  def install_fakes
    install_heroku
    install_curl
  end

  # Writes this call to the fake's own log, then uses the next answer.
  def fake_start(name)
    <<~BASH
      mkdir -p "$SANDBOX_DIR/watch-calls/#{name}"
      printf '%s\n' "$*" >"$SANDBOX_DIR/watch-calls/#{name}/$$"
      answer() {
        local dir="$SANDBOX_DIR/answers/$1" n place
        n=$(<"$dir/count")
        echo $((n + 1)) >"$dir/count"
        place="$dir/$n"
        if [ ! -d "$place" ]; then
          n=0
          while [ -d "$dir/$((n + 1))" ]; do n=$((n + 1)); done
          place="$dir/$n"
        fi
        cat "$place/out"
        cat "$place/err" >&2
        [ ! -f "$place/hang" ] || exec #{@real_sleep} 600
        exit "$(<"$place/code")"
      }
    BASH
  end

  def install_heroku
    sandbox.fake('heroku', <<~BASH)
      #{fake_start('heroku')}
      case "$1 $2" in
        "releases --json") answer releases ;;
        "config:get HEROKU_SLUG_COMMIT") answer commit ;;
        "maintenance -a") answer maintenance ;;
        "ps --json") answer ps ;;
        "pg:psql -c") answer psql ;;
        "pg:backups -a") answer backups ;;
        "logs --tail") answer tail ;;
        "logs -n") answer logs ;;
      esac
      echo "fake heroku: no answer for: $*" >&2
      exit 97
    BASH
  end

  def install_curl
    sandbox.fake('curl', <<~BASH)
      #{fake_start('curl')}
      url="${*: -1}"
      case "$url" in
        */api/v1/version) answer version ;;
        */user/organizations) cat >>"$SANDBOX_DIR/curl-stdin"; answer organizations ;;
        */projects) cat >>"$SANDBOX_DIR/curl-stdin"; answer projects ;;
        */errors*) cat >>"$SANDBOX_DIR/curl-stdin"; answer errors ;;
        *) answer site ;;
      esac
    BASH
  end
end

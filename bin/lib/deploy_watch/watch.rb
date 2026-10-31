# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require 'time'
require_relative 'board'
require_relative 'known_warnings'
require_relative 'reads'
require_relative 'report'
require_relative 'schedule'
require_relative 'shell'

module DeployWatch
  ROOT = File.expand_path('../../..', __dir__)
  KNOWN_LIST = File.join(ROOT, 'docs/deploy-known-warnings.txt')
  RECURRING = File.join(ROOT, 'config/recurring.yml')
  ZONE = 'America/Chicago'
  URLS = { 'comeals-monorepo' => 'https://comeals.com',
           'comeals-staging' => 'https://comeals-staging-ad51b8a1eb64.herokuapp.com' }.freeze
  DEFAULT_MINUTES = 30
  USAGE = 'Usage: [DEPLOY_APP=comeals-staging] bin/watch-deploy [--minutes N]'

  # bin/watch-deploy: returns the exit status. 0 means all was clear.
  def self.main(argv, out: $stdout)
    ENV['TZ'] = ZONE
    minutes = parse_minutes(argv)
    app = ENV.fetch('DEPLOY_APP', 'comeals-monorepo')
    return refuse(out, %(DEPLOY_APP is "#{app}". It must be comeals-monorepo or comeals-staging. Nothing was read.)) unless URLS.key?(app)

    Watch.new(app:, minutes:, out:).run
  rescue OptionParser::ParseError => e
    refuse(out, "#{e.message}\n#{USAGE}")
  rescue StartError, KnownWarnings::ListError => e
    refuse(out, e.message)
  end

  def self.parse_minutes(argv)
    minutes = DEFAULT_MINUTES
    parser = OptionParser.new(USAGE)
    parser.on('--minutes N', Integer, 'How long to watch (default 30)') { |value| minutes = value }
    parser.parse!(argv.dup)
    raise OptionParser::InvalidArgument, "--minutes #{minutes}" unless minutes.positive?

    minutes
  end

  def self.refuse(out, message)
    out.puts(message)
    1
  end

  # The value of NAME in .env, the last line that sets it, without the quotes
  # around it. It reads the file as text, the same way bin/deploy does, and
  # never prints it.
  def self.env_file_value(name, file = '.env')
    return nil unless File.exist?(file)

    lines = File.readlines(file, chomp: true).select { |line| line.start_with?("#{name}=", "export #{name}=") }
    value = lines.last.to_s.split('=', 2).last.to_s.sub(/\A(['"])(.*)\1\z/, '\2')
    value.empty? ? nil : value
  end

  class StartError < StandardError; end

  # The main loop. All state is in the board, and only this thread changes
  # it: the stream and the reads run in threads of their own and put what
  # they got on one queue.
  class Watch
    TICK = 1
    # A tick this much later than it should be means the laptop slept.
    JUMP = 30
    # The app answers this watch's own site check every 30 seconds, so a
    # stream this quiet has hung (we saw one hang every 30 minutes).
    STREAM_QUIET = 180
    STREAM_RETRY = 5
    INTERVALS = { release: 60, dynos: 60, site: 30, database: 60, bugsnag: 120 }.freeze
    PROGRESS_EVERY = 300

    def initialize(app:, minutes:, out:)
      @app = app
      @out = out
      @tty = out.tty?
      @started_at = Time.now
      @ends_at = @started_at + (minutes * 60)
      @events = Queue.new
      # A thread that has ended, for a read that has not started yet.
      @running = Hash.new(Thread.new {}.join)
      @next_read = Hash.new(@started_at)
      @batch = 0
      @restarts = 0
      @next_stream_at = @started_at
      @last_line_at = @started_at
      @printed = {}
      @last_progress = @started_at
      @stopped = false
      @report_path = "tmp/deploy/watch-#{@started_at.utc.strftime('%Y%m%dT%H%M%SZ')}.txt"
      setup
    end

    def run
      trap('INT') { @stopped = true }
      trap('TERM') { @stopped = true }
      FileUtils.mkdir_p(File.dirname(@report_path))
      start_screen
      @last_tick = Time.now
      tick until @stopped || Time.now >= @ends_at
      finish
    ensure
      stop_stream
      Shell.stop_all
    end

    private

    def setup
      token = DeployWatch.env_file_value('BUGSNAG_AUTH_TOKEN')
      @kinds = INTERVALS.keys
      skipped = bugsnag_skip(token)
      @kinds -= [:bugsnag] if skipped
      @reads = Reads.new(app: @app, url: URLS.fetch(@app), since: @started_at, token:)
      first = @reads.read(:release)
      raise StartError, "Could not read #{@app} from Heroku, so the watch did not start. #{first.error}. Check: heroku auth:whoami" unless first.ok

      @first_release = first.data
      @board = Board.new(started_at: @started_at, ends_at: @ends_at, first_release: first.data,
                         known: KnownWarnings.new(KNOWN_LIST, @app), schedule: Schedule.from_file(RECURRING),
                         bugsnag_skipped: skipped)
      @report = Report.new(app: @app, board: @board, started_at: @started_at, ends_at: @ends_at, color: @tty)
    end

    def bugsnag_skip(token)
      return 'staging has no Bugsnag key' if @app == 'comeals-staging'

      'BUGSNAG_AUTH_TOKEN is not in .env' unless token
    end

    def start_screen
      if @tty
        @out.write("\e[2J")
      else
        @out.sync = true
        @out.puts(@report.title, @report.times)
      end
    end

    def tick
      now = Time.now
      note_gap(now)
      drain(now)
      keep_stream(now)
      start_due_reads(now)
      draw(now)
      @last_tick = now
      sleep(TICK)
    end

    def note_gap(now)
      return if now - @last_tick < JUMP

      @board.gap(@last_tick, [now, @ends_at].min)
      @last_line_at = now
    end

    def drain(now)
      until @events.empty?
        kind, *rest = @events.pop
        if kind == :line
          @last_line_at = now
          @board.log.add(*rest)
        else
          @board.apply(kind, rest.first, now)
        end
      end
    end

    def keep_stream(now)
      return if @stream && @stream_thread.alive? && now - @last_line_at < STREAM_QUIET

      if @stream
        @restarts += 1
        stop_stream
      end
      start_stream(now) if now >= @next_stream_at
    end

    def start_stream(now)
      @batch += 1
      batch = @batch
      @next_stream_at = now + STREAM_RETRY
      @last_line_at = now
      @stream = IO.popen(['heroku', 'logs', '--tail', '-n', Reads::LOG_LINES.to_s, '-a', @app], err: File::NULL, pgroup: true)
      @stream_pid = @stream.pid
      stream = @stream
      @stream_thread = Thread.new do
        stream.each_line { |line| @events << [:line, line, batch] }
        stream.close
      end
    end

    def stop_stream
      return unless @stream

      Shell.stop_group(@stream_pid)
      @stream_thread.join
      @stream = nil
    end

    def start_due_reads(now)
      @kinds.each do |kind|
        next if now < @next_read[kind] || @running[kind].alive?

        @next_read[kind] = now + INTERVALS.fetch(kind)
        start_read(kind)
      end
    end

    def start_read(kind)
      @running[kind] = Thread.new { @events << [kind, @reads.read(kind)] }
    end

    def draw(now)
      if @tty
        lines = @report.screen(now, @restarts)
        @out.write("\e[H#{lines.map { |line| "#{line}\e[K\n" }.join}\e[J")
      else
        print_changes(now)
      end
    end

    def print_changes(now)
      @board.rows(now).each do |row|
        next if @printed[row.name] == row.status

        @printed[row.name] = row.status
        @out.puts(@report.plain_row(now, row))
      end
      return if now - @last_progress < PROGRESS_EVERY

      @last_progress = now
      @out.puts(@report.plain_progress(now))
    end

    # One more read of everything, unless the person stopped the watch: the
    # last minute counts too, and a stream that died near the end has not
    # shown it.
    def finish
      stop_stream
      note_gap(Time.now)
      last_reads unless @stopped
      now = Time.now
      drain(now)
      write_report(now)
    end

    def last_reads
      @kinds.each { |kind| start_read(kind) unless @running[kind].alive? }
      @running.each_value(&:join)
      last_logs = @reads.read(:logs)
      drain(Time.now)
      return @board.final_log_read_failed(last_logs.error) unless last_logs.ok

      @batch += 1
      last_logs.data.each_line { |line| @board.log.add(line, @batch) }
    end

    def write_report(now)
      look = @report.needs_look?(now, @stopped)
      rollback = look ? rollback_lines : []
      plain = Report.new(app: @app, board: @board, started_at: @started_at, ends_at: @ends_at, color: false)
      File.write(@report_path, "#{[plain.title, plain.times, '', *final_lines(plain, now, rollback)].join("\n")}\n")
      @out.write("\e[H\e[2J") if @tty
      @out.puts(@report.title, @report.times, '', *final_lines(@report, now, rollback))
      look ? 1 : 0
    end

    def final_lines(report, now, rollback)
      report.final(now, stopped: @stopped, restarts: @restarts, saved_to: @report_path, rollback:)
    end

    # A rollback command only fits when the release is still the one the
    # watch started on.
    def rollback_lines
      if @board.release_changed?
        return ['  The release changed during the watch, so no rollback command is shown.',
                "  Read heroku releases -a #{@app}, then run bin/watch-deploy again for the release that runs now.", '']
      end

      backups = @reads.read(:backups)
      @report.rollback_lines(@first_release[:releases], backups.data)
    end
  end
end

# frozen_string_literal: true

require 'set'
require 'time'
require_relative 'known_warnings'

module DeployWatch
  # Reads Heroku log lines, one at a time, and tells the board what it saw.
  # Lines come from a stream that restarts, and each new stream starts with
  # older lines, so a line seen before is skipped. When a new stream's first
  # line is newer than the last line seen, the lines between them are lost,
  # and the scan says so.
  class LogScan
    LINE = /\A(\S+) (app|heroku)\[([^\]]+)\]:/
    # The same words bin/deploy's log check looks for.
    APP_ERROR = /ERROR|FATAL|RuntimeError|NoMethodError|NameError|TypeError|ArgumentError|PG::|Errno::/
    CODE = /\bcode=([HR]\d+)\b/
    RUNTIME_ERROR = /\bError (R\d+)\b/
    STATUS = /\bstatus=(\d{3})\b/
    SAMPLE = /\Asource=(web|worker)\.\d+ .*sample#memory_total=([\d.]+)MB.*sample#memory_quota=([\d.]+)MB/
    RESTART = /State changed from \S+ to (?!up\b)(\S+)|Cycling|Stopping all processes with SIGTERM/
    SCANNER = 'No route matches'
    # A path that Better Stack and this watch ask for every few minutes. The
    # router line does not say who asked.
    MONITOR_PATHS = ['/', '/api/v1/version'].freeze

    attr_reader :requests, :scanner_lines, :known_lines, :lines, :memory, :last_event

    def initialize(known:, since:, board:)
      @known = known
      @since = since
      @board = board
      @seen = Set.new
      @batch = nil
      @covered_until = since
      @requests = @scanner_lines = @known_lines = @lines = 0
      @memory = {}
    end

    def add(raw, batch)
      line = raw.dup.force_encoding('UTF-8').scrub.chomp
      match = LINE.match(line)
      return unless match

      at = Time.iso8601(match[1])
      note_batch(batch, at)
      @covered_until = [@covered_until, at].max
      scan(line, at, match[3]) if @seen.add?(line) && at >= @since
    rescue ArgumentError
      nil
    end

    private

    def note_batch(batch, at)
      return if batch == @batch

      @batch = batch
      @board.log_gap(@covered_until, at) if at > @covered_until
    end

    def scan(line, at, source)
      @lines += 1
      text = KnownWarnings.clean(line)
      if source == 'router'
        scan_router(line, text, at)
      elsif (sample = SAMPLE.match(text))
        @memory[sample[1]] = [sample[2].to_f.round, sample[3].to_f.round]
      elsif source != 'api'
        scan_dyno(line, text, at, source)
      end
    end

    def scan_router(line, text, at)
      @requests += 1
      @last_event = event(text, at)
      code = CODE.match(text)&.[](1)
      status = STATUS.match(text)&.[](1)
      return unless code || status.to_i >= 500

      if @known.reason(text)
        @known_lines += 1
      else
        @board.problem(:requests, code || "status #{status}", "#{code || status} from the router", line, at)
      end
    end

    def event(text, at)
      method = text[/\bmethod=(\S+)/, 1]
      path = text[/\bpath="([^"]*)"/, 1]
      who = MONITOR_PATHS.include?(path) ? ' (Better Stack or this watch)' : ''
      "#{at.getlocal.strftime('%-I:%M:%S')}  #{method} #{path} #{text[STATUS, 1]}#{who}"
    end

    def scan_dyno(line, text, at, source)
      @scanner_lines += 1 if text.include?(SCANNER)
      return if @known.reason(text)

      runtime = RUNTIME_ERROR.match(text)&.[](1)
      return @board.problem(:requests, runtime, "#{runtime} from #{source}", line, at) if runtime
      return note_restart(line, at, source) if text.match?(RESTART)

      error = APP_ERROR.match(text)&.[](0)
      if error
        @board.problem(:app_errors, error, "#{error} in the app log", line, at)
      elsif text.match?(KnownWarnings::WARNING)
        @board.problem(:warnings, text, "New warning: #{text}", line, at)
      end
    end

    # A one-off dyno (run.1234) starts and stops as its work needs.
    def note_restart(line, at, source)
      type = source[/\A(web|worker)\./, 1]
      @board.problem(type.to_sym, "restart #{source}", "#{source} restarted", line, at) if type
    end
  end
end

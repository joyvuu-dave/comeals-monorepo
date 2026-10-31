# frozen_string_literal: true

require 'time'

module DeployWatch
  # The screen while the watch runs, and the report at the end.
  class Report
    MARKS = { ok: '✅', fail: '❌', unknown: '❓', wait: '⏳', warn: '⚠️ ', not_checked: '➖' }.freeze
    WORDS = { ok: 'ok', fail: 'PROBLEM', unknown: 'UNKNOWN', wait: 'waiting', warn: 'WARNING', not_checked: 'skipped' }.freeze
    BAR = 30
    # The checks whose count means lines or answers seen. The others count
    # reads, which says nothing.
    COUNTED = %i[requests app_errors warnings site].freeze
    COLORS = { green: 32, red: 31, yellow: 33 }.freeze

    def initialize(app:, board:, started_at:, ends_at:, color:)
      @app = app
      @board = board
      @started_at = started_at
      @ends_at = ends_at
      @color = color
    end

    def title
      "Comeals deploy watch · #{@app} · v#{@board.version} (#{@board.commit[0, 8]})"
    end

    def times
      "Started #{clock(@started_at)} · ends #{clock(@ends_at)}"
    end

    # The lines of the screen, for a terminal.
    def screen(now, restarts)
      seen = [now - @started_at, 0].max
      whole = @ends_at - @started_at
      part = [seen / whole, 1].min
      filled = (part * BAR).floor
      bar = "#{paint('█' * filled, :green)}#{'░' * (BAR - filled)}"
      event = @board.log.last_event
      ['', "  #{title}", "  #{times}", '',
       "  #{bar}  #{(part * 100).floor}%   #{span(seen)} of #{span(whole)}   #{span(whole - seen)} left", '',
       *row_lines(@board.rows(now)), '',
       ("  Last event #{event}" if event),
       *restart_lines(restarts),
       *gap_lines].compact
    end

    # The whole report at the end. `rollback` is the lines of #rollback_lines,
    # or none when all was clear.
    def final(now, stopped:, restarts:, saved_to:, rollback:)
      rows = @board.rows(now)
      needs_look = needs_look?(now, stopped)
      [
        banner(needs_look),
        watched_line(now, stopped, rows),
        '',
        *(needs_look ? look_lines(now, stopped, rows) : []),
        *rollback,
        *row_lines(rows),
        '',
        *restart_lines(restarts),
        "  Report saved in #{saved_to}"
      ]
    end

    def needs_look?(now, stopped)
      stopped || @board.gaps.any? || @board.rows(now).any? { |row| %i[fail unknown warn].include?(row.status) }
    end

    # One plain line for a row, for output that is not a terminal.
    def plain_row(now, row)
      "#{now.strftime('%-I:%M:%S %P')}  #{row.name}: #{WORDS.fetch(row.status)}: #{row.text}"
    end

    def plain_progress(now)
      "#{now.strftime('%-I:%M:%S %P')}  #{span(now - @started_at)} of #{span(@ends_at - @started_at)}"
    end

    def rollback_lines(releases, backups_text)
      target, deploy_at = rollback_target(releases)
      backup = backup_before(backups_text, deploy_at)
      base = "gh workflow run rollback.yml --ref main -f app=#{@app} -f release=#{target}"
      reason = %(-f reason="Problems after the deploy of #{@board.commit[0, 8]}, seen by bin/watch-deploy")
      [
        '  If you decide to roll back (docs/runbooks/undo-a-deploy.md):',
        '  If no migration ran, this rolls back only the code. The workflow refuses it if a migration ran:',
        "    #{base} #{reason}",
        '  If a migration ran, this also restores the backup, and loses every write since:',
        "    #{base} -f backup=#{backup} #{reason}",
        ''
      ]
    end

    private

    def row_lines(rows)
      rows.map do |row|
        if @color
          "  #{MARKS.fetch(row.status)} #{row.name.ljust(14)} #{row.text}"
        else
          "  #{WORDS.fetch(row.status).ljust(8)} #{row.name.ljust(14)} #{row.text}"
        end
      end
    end

    def banner(needs_look)
      needs_look ? paint('  NEEDS A LOOK', :red) : paint('  ALL CLEAR', :green)
    end

    def watched_line(now, stopped, rows)
      problems = @board.problems.size
      checks = rows.count { |row| row.status != :not_checked }
      unknown = rows.select { |row| row.status == :unknown }.map { |row| " Could not check: #{row.name}." }.join
      skipped = rows.select { |row| row.status == :not_checked }.map { |row| " Not checked: #{row.name}." }.join
      "  Watched v#{@board.version} for #{watched_text(now, stopped)}. " \
        "#{checks} checks, #{problems} #{problems == 1 ? 'problem' : 'problems'}.#{unknown}#{skipped}"
    end

    def watched_text(now, stopped)
      seen = [@board.watched_seconds(now), @ends_at - @started_at].min
      whole = @ends_at - @started_at
      return "#{(seen / 60).floor} of #{minutes(whole)}" if stopped || @board.gaps.any?

      minutes(whole)
    end

    def minutes(seconds)
      count = (seconds / 60).round
      "#{count} #{count == 1 ? 'minute' : 'minutes'}"
    end

    def look_lines(now, stopped, rows)
      lines = []
      lines << "  The watch was stopped by hand at #{clock(now)}. The time after that was not watched." if stopped
      lines.concat(gap_lines)
      @board.problems.each { |item| lines.concat(problem_lines(item)) }
      rows.select { |row| row.status == :unknown }.each { |row| lines << "  #{row.name}: #{row.text}" }
      lines << ''
    end

    def problem_lines(item)
      times = item.count > 1 && COUNTED.include?(item.check) ? " (#{item.count} times)" : ''
      ["  #{item.check.to_s.tr('_', ' ').capitalize}: #{item.text}#{times}, first at #{item.at.getlocal.strftime('%-I:%M:%S %P %Z')}",
       *("      #{item.first_line}" if item.first_line)]
    end

    def gap_lines
      @board.gaps.map do |from, to|
        "  The watch had a gap from #{clock(from)} to #{clock(to)} (#{span(to - from)}). " \
          'The laptop may have slept. Nothing was seen in that time.'
      end
    end

    def restart_lines(restarts)
      restarts.positive? ? ["  Log stream restarted: #{restarts}"] : []
    end

    # The release to go back to is the one before the release that put the
    # running code in place. A later config change makes a newer release
    # with the same code, so going back one would change nothing.
    def rollback_target(releases)
      deploy = releases.index { |release| release['description'].to_s.match?(/\A(Deploy|Rollback)\b/) } || 0
      target = releases.drop(deploy + 1).find { |release| release['status'] == 'succeeded' }
      name = target ? "v#{target['version']}" : %("<the release before this deploy, in: heroku releases -a #{@app}>")
      [name, releases.fetch(deploy)['created_at']]
    end

    def backup_before(text, deploy_at)
      found = text.to_s.lines.filter_map { |line| line.match(/\A\s*([a-z]\d+)\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4})\s+Completed/) }
                  .find { |match| Time.parse(match[2]) < Time.iso8601(deploy_at.to_s) }
      found ? found[1] : %("<the newest backup before the deploy, in: heroku pg:backups -a #{@app}>")
    end

    def span(seconds)
      whole = seconds.to_i
      format('%<minutes>d:%<seconds>02d', minutes: whole / 60, seconds: whole % 60)
    end

    def clock(time)
      time.getlocal.strftime('%-I:%M %P %Z')
    end

    def paint(text, color)
      @color ? "\e[#{COLORS.fetch(color)}m#{text}\e[0m" : text
    end
  end
end

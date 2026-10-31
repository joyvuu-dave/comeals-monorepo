# frozen_string_literal: true

require_relative 'log_scan'

module DeployWatch
  # What the watch knows, and what each check says about it. Only the main
  # thread of the watch changes it. It takes the time as an argument, so a
  # spec can run any scenario without waiting.
  class Board
    Problem = Struct.new(:check, :key, :text, :first_line, :at, :count)
    Row = Struct.new(:name, :status, :text)
    ReadState = Struct.new(:total, :last_ok, :longest_blind, :error)

    # Solid Queue writes a heartbeat every 60 seconds (lib/solid_queue_check.rb).
    PROCESS_KINDS = %w[Supervisor Dispatcher Worker Scheduler].freeze
    HEARTBEAT_WITHIN = 120
    # A job due less than this long ago is not yet called late.
    JOB_GRACE = 300
    # VerifyLedgerJob runs every night.
    LEDGER_WITHIN = 26 * 3600
    # One failed read followed by a good one still shows the check as seen.
    # Longer than this with no good read, the check could not see those
    # minutes, and says so.
    MOST_BLIND = 300

    attr_reader :problems, :gaps, :log, :version, :commit

    def initialize(started_at:, ends_at:, known:, schedule:, first_release:, bugsnag_skipped:)
      @started_at = started_at
      @ends_at = ends_at
      @schedule = schedule
      @first = first_release
      @version = first_release[:version]
      @commit = first_release[:commit]
      @maintenance = first_release[:maintenance]
      @bugsnag_skipped = bugsnag_skipped
      @problems = []
      @gaps = []
      @reads = Hash.new { |hash, kind| hash[kind] = ReadState.new(0, started_at, 0, nil) }
      @dynos = {}
      @first_updated = {}
      @log = LogScan.new(known:, since: started_at, board: self)
      @log_error = nil
      @site_codes = Hash.new(0)
      @site_reads = 0
      @database = nil
      @jobs_seen = []
    end

    def problem(check, key, text, first_line, at)
      found = @problems.find { |item| item.check == check && item.key == key }
      found&.count += 1
      return found if found

      Problem.new(check, key, text, first_line, at, 1).tap { |item| @problems << item }
    end

    def apply(kind, reading, now)
      state = @reads[kind]
      state.total += 1
      return state.error = reading.error unless reading.ok

      state.longest_blind = [state.longest_blind, now - state.last_ok].max
      state.last_ok = now
      state.error = nil
      send("apply_#{kind}", reading.data, now)
    end

    # The laptop slept, or the process stopped: nothing was seen from..to.
    def gap(from, to)
      @gaps << [from, to]
      @reads.each_value { |state| state.last_ok = to }
    end

    def log_gap(from, to)
      local = [from, to].map { |time| time.getlocal.strftime('%-I:%M:%S %P') }
      @log_error = "the log lines from #{local.first} to #{local.last} were lost"
    end

    def final_log_read_failed(error)
      @log_error = "the last read of the log failed (#{error})"
    end

    def release_changed? = @problems.any? { |item| item.key == 'release changed' }

    # Seconds actually seen, up to now.
    def watched_seconds(now)
      ([now, @ends_at].min - @started_at) - @gaps.sum { |from, to| to - from }
    end

    def rows(now)
      [
        row('Release', :release, [:release]) { "v#{@version} running #{@commit[0, 8]}, maintenance #{@maintenance}" },
        row('Web', :web, [:dynos]) { dyno_text('web', ' · no restarts') },
        row('Worker', :worker, %i[dynos database]) { dyno_text('worker', " · #{heartbeat_text}") },
        row('Site', :site, [:site]) { site_text },
        row('Requests', :requests, [:logs]) { requests_text },
        row('App errors', :app_errors, [:logs]) { app_errors_text },
        jobs_row(now),
        row('Failed jobs', :failed_jobs, [:database]) { failed_text },
        row('Ledger', :ledger, [:database]) { ledger_text(now) },
        warnings_row,
        bugsnag_row
      ]
    end

    private

    # A check with a problem shows the first one. Then a failed read shows,
    # then a check with no read yet waits, and only then the check passes.
    def row(name, check, kinds)
      mine = @problems.select { |item| item.check == check }
      return Row.new(name, :fail, problem_text(mine)) unless mine.empty?

      unknown = kinds.filter_map { |kind| unknown_text(kind) }.first
      return Row.new(name, :unknown, "could not check: #{unknown}") if unknown
      return Row.new(name, :wait, 'waiting for the first read') if kinds.any? { |kind| never_read?(kind) }

      Row.new(name, :ok, yield)
    end

    def problem_text(items)
      more = items.size > 1 ? " · and #{items.size - 1} more" : ''
      "#{items.first.text}#{more}"
    end

    def never_read?(kind)
      kind == :logs ? @log.lines.zero? : @reads[kind].total.zero?
    end

    def unknown_text(kind)
      return @log_error if kind == :logs

      state = @reads[kind]
      return state.error if state.error

      "no good read for #{(state.longest_blind / 60).round} minutes" if state.longest_blind > MOST_BLIND
    end

    def apply_release(data, now)
      @version = data[:version]
      @commit = data[:commit]
      @maintenance = data[:maintenance]
      if @version != @first[:version] || @commit != @first[:commit]
        problem(:release, 'release changed', "The release changed from v#{@first[:version]} (#{@first[:commit][0, 8]}) to " \
                                             "v#{@version} (#{@commit[0, 8]})", data[:releases].first['description'], now)
      end
      problem(:release, 'maintenance', 'Maintenance mode was turned on', nil, now) if @maintenance == 'on'
      problem(:release, 'status', "Release v#{@version} has status #{data[:status]}", nil, now) if data[:status] != 'succeeded'
    end

    def apply_dynos(data, now)
      %w[web worker].each do |type|
        mine = data.select { |dyno| dyno[:type] == type }
        @dynos[type] = mine
        problem(type.to_sym, 'none', "No #{type} dyno is running", nil, now) if mine.empty?
        mine.each { |dyno| check_dyno(type.to_sym, dyno, now) }
      end
    end

    def check_dyno(check, dyno, now)
      name = dyno[:name]
      problem(check, "state #{name}", "#{name} was #{dyno[:state]}", nil, now) if dyno[:state] != 'up'
      problem(check, "version #{name}", "#{name} runs v#{dyno[:version]}", nil, now) if dyno[:version] != @first[:version]
      first = @first_updated[name] ||= dyno[:updated_at]
      problem(check, "restart #{name}", "#{name} restarted", nil, now) if dyno[:updated_at] != first
    end

    def apply_site(data, now)
      @site_reads += 1
      data.each do |path, code|
        @site_codes[path] = code
        problem(:site, "#{path} #{code}", "#{path} answered #{code}", nil, now) if code != '200'
      end
    end

    def apply_database(data, now)
      @database = data
      check_heartbeats(data[:heartbeats], now)
      check_failed(data, now)
      check_ledger(data[:ledger], now)
      check_jobs(data[:jobs], now)
    end

    def check_heartbeats(heartbeats, now)
      PROCESS_KINDS.each do |kind|
        age = heartbeats[kind]
        next if age && age <= HEARTBEAT_WITHIN

        problem(:worker, "heartbeat #{kind}", "Solid Queue #{kind} has no fresh heartbeat", age && "last one #{age} s ago", now)
      end
    end

    def check_failed(data, now)
      return unless data[:failed_new].positive?

      problem(:failed_jobs, 'new', '', data[:failed_first], now).text = "#{data[:failed_new]} new"
    end

    def check_ledger(ledger, now)
      return problem(:ledger, 'none', 'No ledger check has ever run', nil, now) unless ledger

      summary = ledger_summary(ledger, now)
      problem(:ledger, 'mismatch', "#{summary}: #{ledger[:mismatches]} mismatches", nil, now) if ledger[:mismatches].positive?
      problem(:ledger, 'error', "#{summary}: it failed", ledger[:error], now) unless ledger[:error].empty?
      problem(:ledger, 'old', "#{summary}: that is too long ago", nil, now) if now - ledger[:at] > LEDGER_WITHIN
    end

    def check_jobs(jobs, now)
      @jobs_seen = jobs
      finished = jobs.select { |job| job[:finished] }.map { |job| [job[:key], job[:at].to_i] }
      @schedule.due(@started_at, now - JOB_GRACE).each do |key, at|
        next if finished.include?([key, at.to_i])

        problem(:jobs, "#{key} #{at.to_i}", "#{key} was due at #{clock(at)} and did not finish", nil, now)
      end
    end

    def apply_bugsnag(data, now)
      data.each do |error|
        problem(:bugsnag, error[:name], "New Bugsnag error: #{error[:name]}", [error[:message], error[:context]].compact.join(' at '), now)
      end
    end

    def dyno_text(type, tail)
      dynos = @dynos.fetch(type, [])
      memory = @log.memory[type]
      used = if memory
               " · #{memory[0]} MB#{" of #{memory[1]} MB" if type == 'web'}"
             end
      "#{dynos.map { |dyno| dyno[:state] }.uniq.join(', ')}#{used}#{tail}"
    end

    def heartbeat_text
      "Solid Queue heartbeat #{@database[:heartbeats].values.max} s ago"
    end

    def site_text
      summary = @site_codes.keys.join('  and  ')
      "#{summary} → 200 (checked #{@site_reads} #{@site_reads == 1 ? 'time' : 'times'})"
    end

    def requests_text
      known = @log.known_lines.positive? ? " · #{@log.known_lines} known lines ignored" : ''
      "#{@log.requests} · no 5xx · no H or R codes#{known}"
    end

    def app_errors_text
      @log.scanner_lines.positive? ? "none (404 scanner lines ignored: #{@log.scanner_lines})" : 'none'
    end

    def jobs_row(now)
      return Row.new('Jobs', :unknown, "could not check: cannot read the schedule of #{@schedule.unread.join(', ')}") if @schedule.unread.any?

      base = row('Jobs', :jobs, [:database]) { jobs_text(now) }
      base.status = :wait if base.status == :ok && @jobs_seen.none? { |job| job[:finished] }
      base
    end

    def jobs_text(now)
      finished = @jobs_seen.select { |job| job[:finished] }
      next_job = @schedule.next_after(now)
      upcoming = next_job ? "next: #{next_job.first} #{clock(next_job.last)}" : 'no job in the next two days'
      return "no scheduled job due before #{clock(@ends_at)} (#{upcoming})" if finished.empty? && (!next_job || next_job.last > @ends_at)
      return "none finished yet (#{upcoming})" if finished.empty?

      "#{finished.size} finished (last: #{finished.last[:key]} #{clock(finished.last[:at])})"
    end

    def failed_text
      older = @database[:failed_old].positive? ? " (#{@database[:failed_old]} older)" : ''
      "0#{older}"
    end

    def ledger_text(now)
      "#{ledger_summary(@database[:ledger], now)}: #{@database[:ledger][:checked]} settlements, 0 mismatches"
    end

    def ledger_summary(ledger, now)
      format = ledger[:at].getlocal.to_date == now.getlocal.to_date ? '%-I:%M %P' : '%b %-d %-I:%M %P'
      "last check #{ledger[:at].getlocal.strftime(format)}"
    end

    def warnings_row
      mine = @problems.select { |item| item.check == :warnings }
      return Row.new('Warnings', :warn, "#{mine.size} new · see below") unless mine.empty?
      return Row.new('Warnings', :unknown, "could not check: #{@log_error}") if @log_error
      return Row.new('Warnings', :wait, 'waiting for the first read') if @log.lines.zero?

      Row.new('Warnings', :ok, 'none new')
    end

    def bugsnag_row
      return Row.new('Bugsnag', :not_checked, "not checked: #{@bugsnag_skipped}") if @bugsnag_skipped

      row('Bugsnag', :bugsnag, [:bugsnag]) { 'no new Bugsnag errors' }
    end

    def clock(time)
      time.getlocal.strftime('%-I:%M %P')
    end
  end
end

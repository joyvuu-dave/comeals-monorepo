# frozen_string_literal: true

module Storm
  # What must be true of Solid Queue after a storm in which the jobs ran
  # in a real bin/jobs process (bin/storm with STORM_SOLID_QUEUE=1).
  # Returns a list of problems, empty when all is well.
  #
  #   - no job ended in solid_queue_failed_executions. Nothing in the
  #     storm makes a job fail on purpose: Pusher is a no-op and mail goes
  #     to the test delivery method, so a failed job is a job that raised;
  #   - no job is claimed by a process that is gone. Solid Queue fails or
  #     releases those itself when it notices, so one left over means it
  #     did not notice;
  #   - every registered process has beaten within the alive threshold.
  #     A late heartbeat is what makes Solid Queue prune a live process
  #     and fail the jobs it was running;
  #   - the jobs log has no conflict, deadlock, thread error or failed
  #     perform in it (LOG_ERRORS);
  #   - every report in the error log is one the storm allows
  #     (ErrorLog.problem);
  #   - every jobs process is still running.
  class QueueChecks
    CONFLICT_LINES = Regexp.union('could not serialize', 'SerializationFailure', 'deadlock detected', 'Deadlocked')
    LOG_ERRORS = Regexp.union(CONFLICT_LINES, 'Error in thread', 'Error performing', 'Error while',
                              'Error deregistering', 'ConnectionTimeoutError', 'could not obtain', 'PG::',
                              'Errno::', 'stack level too deep')

    def self.call(jobs_log:, error_log:, pids:)
      new(jobs_log: jobs_log, error_log: error_log, pids: pids).call
    end

    # Numbers for the run's report: how many jobs finished and failed,
    # how many conflicts the jobs and the app tried again, and how many
    # conflict lines the jobs log has.
    def self.summary(jobs_log:, error_log:)
      reports = ErrorLog.read(error_log)
      { finished: SolidQueue::Job.where.not(finished_at: nil).count,
        failed: SolidQueue::FailedExecution.count,
        by_class: SolidQueue::Job.group(:class_name).count,
        conflicts_retried: reports.count { |entry| ErrorLog.retried_conflict?(entry) },
        conflicts_retried_by_process: reports.select { |entry| ErrorLog.retried_conflict?(entry) }
                                             .pluck('process').tally,
        conflict_lines: log_lines(jobs_log).count { |line| line.match?(CONFLICT_LINES) } }
    end

    # Waits until every job with an id up to `mark` has finished or
    # failed. Jobs after the mark are the scheduler's, still coming in
    # while this waits. Returns a problem, or nil.
    def self.drain(mark:, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        left = SolidQueue::Job.where(id: ..mark, finished_at: nil).where.missing(:failed_execution)
        return if left.none?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          return "the queue did not drain in #{timeout} s: #{left.count} job(s) left " \
                 "(#{left.group(:class_name).count.inspect})"
        end

        sleep(0.1)
      end
    end

    # Everything the storm task checks about the queue after a storm with
    # STORM_SOLID_QUEUE=1, in order: wait for the queue to drain; check it
    # with the jobs processes still running (heartbeats, alive); stop them
    # the way Heroku does (TERM), and check that each exited cleanly, left
    # no process row and no claim behind, and logged no error on the way
    # out.
    def self.after_storm(jobs:, error_log:, drain_timeout:, say: ->(_line) {})
      mark = SolidQueue::Job.maximum(:id).to_i
      waiting = SolidQueue::Job.where(finished_at: nil).count
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      problems = [drain(mark: mark, timeout: drain_timeout)].compact
      say.call "==> queue: #{waiting} job(s) not finished at the end of the storm, " \
               "drained in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)} s"
      jobs.each(&:alive?)
      problems += call(jobs_log: jobs.first.log, error_log: error_log, pids: jobs.map(&:pid))
      jobs.each do |process|
        status = process.stop
        problems << "the jobs process (pid #{process.pid}) exited with #{status.inspect}" unless status&.success?
        problems += call(jobs_log: process.log, error_log: error_log, pids: [])
      end
      left = SolidQueue::Process.count
      problems << "#{left} Solid Queue process row(s) left after the stop" if left.positive?
      problems.uniq
    end

    def self.log_lines(path)
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    def initialize(jobs_log:, error_log:, pids:)
      @jobs_log = jobs_log
      @error_log = error_log
      @pids = pids
      @problems = []
    end

    def call
      check_failed
      check_claims
      check_heartbeats
      check_jobs_log
      check_reports
      check_processes_alive
      @problems
    end

    private

    def check_failed
      SolidQueue::FailedExecution.includes(:job).order(:job_id).each do |failed|
        @problems << "job #{failed.job_id} #{failed.job.class_name} failed: " \
                     "#{failed.exception_class}: #{failed.message.to_s[0, 300]}"
      end
    end

    def check_claims
      SolidQueue::ClaimedExecution.where.missing(:process).includes(:job).order(:job_id).each do |claim|
        @problems << "job #{claim.job_id} #{claim.job.class_name} is claimed by process #{claim.process_id}, " \
                     'which is gone'
      end
    end

    def check_heartbeats
      stale = SolidQueue::Process.where(last_heartbeat_at: ..SolidQueue.process_alive_threshold.ago)
      stale.order(:id).each do |process|
        @problems << "process #{process.id} (#{process.kind}) last beat at #{process.last_heartbeat_at.iso8601(3)}, " \
                     "more than #{SolidQueue.process_alive_threshold.inspect} ago"
      end
    end

    def check_jobs_log
      self.class.log_lines(@jobs_log).each_with_index do |line, index|
        @problems << "jobs log line #{index + 1}: #{line[0, 300]}" if line.match?(LOG_ERRORS)
      end
    end

    def check_reports
      @problems.concat(ErrorLog.read(@error_log).filter_map { |entry| ErrorLog.problem(entry) }.uniq)
    end

    def check_processes_alive
      @pids.each do |pid|
        Process.kill(0, pid)
      rescue Errno::ESRCH
        @problems << "the jobs process (pid #{pid}) died"
      end
    end
  end
end

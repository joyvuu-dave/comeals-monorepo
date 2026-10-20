# frozen_string_literal: true

module Storm
  # A real `bin/jobs --mode async` process beside the storm server, the
  # way the worker dyno runs it (Procfile): Solid Queue's supervisor with
  # its dispatcher, worker and scheduler as threads, and a pool of 12.
  # bin/storm's storm task starts it after the seed, because the catch-up
  # Solid Queue runs at start (RecurringCatchUp) queues every nightly job,
  # and those need the community to exist.
  #
  # What differs from production is in the files it is given: the
  # intervals (spec/support/storm/queue.yml), the schedule
  # (spec/support/storm/recurring.yml), and the heartbeat
  # (STORM_SQ_HEARTBEAT, read by config/environments/test.rb). Pusher is
  # a no-op (INTEGRATION_SERVER) and mail goes to the test delivery
  # method, as in every test process.
  class JobsProcess
    POOL = 12
    # The supervisor, the dispatcher, the worker and the scheduler each
    # register a row.
    PROCESSES = 4

    attr_reader :pid, :log, :status

    def initialize(log:)
      @log = log
    end

    def env
      { 'RAILS_ENV' => 'test', 'INTEGRATION_SERVER' => '1', 'INTEGRATION_SERVER_CACHE' => 'solid',
        'INTEGRATION_SERVER_QUEUE' => 'solid_queue', 'RAILS_DB_POOL' => POOL.to_s,
        'SOLID_QUEUE_CONFIG' => 'spec/support/storm/queue.yml',
        'SOLID_QUEUE_RECURRING_SCHEDULE' => 'spec/support/storm/recurring.yml',
        'STORM_PROCESS' => 'jobs', 'STORM_LOG_TO_STDOUT' => '1',
        # Never ping healthchecks.io or Bugsnag from a storm.
        'HEALTHCHECKS_PING_KEY' => nil, 'BUGSNAG_API_KEY' => nil }
    end

    def start
      @pid = ::Process.spawn(env, 'bin/jobs', '--mode', 'async', chdir: Rails.root.to_s,
                                                                 out: [log.to_s, 'w'], err: %i[child out])
      self
    end

    # Waits until all four of its processes have registered.
    def wait_until_registered(timeout: 90)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
      until SolidQueue::Process.where(pid: pid).count >= PROCESSES
        raise "the jobs process (pid #{pid}) exited before it registered: #{tail}" unless alive?
        raise "the jobs process (pid #{pid}) did not register in #{timeout} s: #{tail}" if past?(deadline)

        sleep(0.2)
      end
    end

    # Reaps the process when it has exited, so a dead one is not counted
    # as alive for being a zombie.
    def alive?
      return false if status

      reaped = ::Process.wait2(pid, ::Process::WNOHANG)
      @status = reaped&.last
      status.nil?
    end

    # Asks it to stop the way Heroku does (TERM), and waits.
    def stop(timeout: 30)
      return status unless alive?

      ::Process.kill('TERM', pid)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
      sleep(0.1) while alive? && !past?(deadline)
      if alive?
        ::Process.kill('KILL', pid)
        @status = ::Process.wait2(pid).last
      end
      status
    end

    private

    def past?(deadline)
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
    end

    def tail
      File.exist?(log) ? File.readlines(log).last(10).join : '(no log)'
    end
  end
end

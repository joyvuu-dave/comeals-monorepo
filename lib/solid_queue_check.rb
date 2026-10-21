# typed: true
# frozen_string_literal: true

# Check after a deploy that Solid Queue is really running.
#
# Since 2026-09-15 every live update is a Solid Queue job (ADR 0007), and
# the nightly jobs run from config/recurring.yml. Both need Solid Queue's
# supervisor, which runs on its own dyno (`worker: env RAILS_DB_POOL=12
# bin/jobs --mode async` in the Procfile) with a dispatcher, a worker and
# a scheduler as threads of its process. Each of the four still writes
# its own heartbeat row. A release can be fine and the worker dyno still be at 0 or
# fail to start, so bin/deploy, the weekly workflow and the staging
# rehearsal run `deploy:verify_solid_queue` afterwards: every process kind
# must have a fresh heartbeat.
#
# A heartbeat says a process is alive, not that its work succeeds. On
# staging on 2026-10-20 every heartbeat was fresh while the scheduler
# failed at every tick (a TransactionIsolationError, ADR 0005 decision
# 10). So `deploy:verify_recurring_job` runs after the heartbeat check: it
# queues a recurring task through the scheduler's own code and waits until
# the worker has run it.
module SolidQueueCheck
  extend T::Sig

  APP = 'comeals-monorepo'
  # What config/queue.yml and config/recurring.yml start: the supervisor,
  # one dispatcher, one worker, and the scheduler for the recurring jobs.
  PROCESS_KINDS = %w[Supervisor Dispatcher Worker Scheduler].freeze
  # Solid Queue writes a heartbeat every 60 seconds by default.
  HEARTBEAT_WITHIN = 2.minutes

  # The process kinds with no fresh heartbeat, as a sentence, or nil when
  # every kind is alive.
  sig { params(alive_kinds: T::Array[String]).returns(T.nilable(String)) }
  def self.process_problem(alive_kinds)
    dead = PROCESS_KINDS - alive_kinds
    return nil if dead.empty?

    "Solid Queue is not fully running: no heartbeat in the last #{HEARTBEAT_WITHIN.inspect} from " \
      "#{dead.join(', ')}. Live updates and the nightly jobs depend on it. " \
      "Check that the worker dyno runs (heroku ps -a #{APP}) and read its log " \
      "(heroku logs -a #{APP} --dyno worker | grep SolidQueue)."
  end

  # The task the run check queues: it deletes guest-add keys older than 7
  # days (config/recurring.yml). It runs every hour anyway, so one more run
  # changes nothing, and it is safe on production. The check writes only
  # Solid Queue's own rows: the job, its run record, and what the worker
  # writes while it runs the job.
  RUN_CHECK_TASK = 'delete_expired_guest_add_keys'
  # The worker looks for jobs every 5 seconds (config/queue.yml), and the
  # cleanup takes well under a second, so two minutes is a lot.
  RUN_WITHIN = 2.minutes
  POLL_EVERY = 2

  # Queues RUN_CHECK_TASK the way the scheduler queues it at a tick
  # (RecurringTask#enqueue), waits until the worker has run it, and
  # returns a sentence that says how long that took. Raises, with Solid
  # Queue's error, when the task cannot be queued, when the job fails, or
  # when it has not run within `within`. `sleeper` waits between looks.
  sig do
    params(within: ActiveSupport::Duration,
           sleeper: T.any(Method, T.proc.params(seconds: Integer).void)).returns(String)
  end
  def self.verify_recurring_run!(within: RUN_WITHIN, sleeper: ->(seconds) { sleep(seconds) })
    task = SolidQueue::RecurringTask.find_by(key: RUN_CHECK_TASK)
    unless task
      raise "There is no recurring task #{RUN_CHECK_TASK}: the scheduler has not saved its tasks. " \
            'It saves them from config/recurring.yml when it starts.'
    end

    queued_at = Time.current
    job_id = enqueue_like_the_scheduler(task, queued_at)
    waits_left = (within.to_f / POLL_EVERY).ceil
    loop do
      done = finished_run(job_id, queued_at)
      return done if done

      if waits_left.zero?
        status = SolidQueue::Job.find(job_id).status || 'waiting'
        raise "the worker did not run #{RUN_CHECK_TASK} within #{within.inspect}; it is #{status}"
      end

      waits_left -= 1
      sleeper.call(POLL_EVERY)
    end
  end

  # The scheduler's own call. It answers false, and only reports the
  # error, when the job cannot be queued; the error is in the payload of
  # its notification.
  sig { params(task: SolidQueue::RecurringTask, at: ActiveSupport::TimeWithZone).returns(T.untyped) }
  def self.enqueue_like_the_scheduler(task, at)
    payload = T.let({}, T::Hash[Symbol, T.untyped])
    callback = ->(*, event_payload) { payload = event_payload }
    job = ActiveSupport::Notifications.subscribed(callback, 'enqueue_recurring_task.solid_queue') do
      task.enqueue(at: at)
    end
    return job.provider_job_id if job

    reason = payload[:enqueue_error] || (payload[:skipped] && 'a run at that time is already recorded')
    raise "could not queue #{RUN_CHECK_TASK}: #{reason || 'Solid Queue gave no reason'}"
  end
  private_class_method :enqueue_like_the_scheduler

  # The sentence for a run that finished, nil while it has not. Raises for
  # a job that failed.
  sig do
    params(job_id: Integer, queued_at: ActiveSupport::TimeWithZone).returns(T.nilable(String))
  end
  def self.finished_run(job_id, queued_at)
    job = SolidQueue::Job.find(job_id)
    failed = job.failed_execution
    raise "#{RUN_CHECK_TASK} failed on the worker: #{failed.exception_class}: #{failed.message}" if failed
    return nil unless job.finished?

    # Two dynos' clocks can differ by a little, so never below zero.
    seconds = [(T.must(job.finished_at) - queued_at).round, 0].max
    "the worker ran #{RUN_CHECK_TASK} #{seconds} s after it was queued"
  end
  private_class_method :finished_run

  sig { void }
  def self.verify_processes!
    # The supervisor saves its kind with its mode, "Supervisor(fork)" or
    # "Supervisor(async)" (SolidQueue::Supervisor#kind), so the mode is
    # cut off before the kinds are compared.
    alive = SolidQueue::Process.where(last_heartbeat_at: HEARTBEAT_WITHIN.ago..).pluck(:kind)
                               .map { |kind| kind.to_s.sub(/\(\w+\)\z/, '') }
    problem = process_problem(alive)
    raise problem if problem
  end
end

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

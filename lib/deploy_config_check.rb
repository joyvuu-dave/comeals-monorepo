# typed: true
# frozen_string_literal: true

# Refuse a production release that is missing the config vars this code
# needs, and check afterwards that Solid Queue is really running.
#
# Since 2026-09-15 every live update is a Solid Queue job (ADR 0007), and
# the four nightly jobs run from config/recurring.yml. Both need Solid
# Queue's supervisor, which SOLID_QUEUE_IN_PUMA starts inside the web dyno
# (config/puma.rb), and the supervisor's processes each hold a database
# connection, so RAILS_DB_POOL has to be at least 4 (the runbook says
# why). Neither var is in git. A deploy that forgets them keeps saving
# writes but tells no open screen to refetch, and runs no nightly job,
# with nothing in the logs to say so.
#
# So the Procfile's release phase runs `deploy:verify_config` before the
# migration. A release phase that exits non-zero is not deployed: Heroku
# keeps the previous release serving, on both deploy paths (bin/deploy
# and the weekly promote in .github/workflows/deploy.yml). And after the
# deploy, `deploy:verify_solid_queue` checks that every Solid Queue
# process has a fresh heartbeat, because a var can be set and the
# supervisor can still fail to start.
#
# Staging (COMEALS_STAGING) and a laptop running the production
# environment (LOCAL_PRODUCTION, bin/prod) are not held to this: staging
# must not run jobs (bin/staging-rehearsal), and a laptop has no Heroku
# config at all.
module DeployConfigCheck
  extend T::Sig

  APP = 'comeals-monorepo'
  MIN_POOL = 4
  # What config/queue.yml and config/recurring.yml start: the supervisor,
  # one dispatcher, one worker, and the scheduler for the recurring jobs.
  PROCESS_KINDS = %w[Supervisor Dispatcher Worker Scheduler].freeze
  # Solid Queue writes a heartbeat every 60 seconds by default.
  HEARTBEAT_WITHIN = 2.minutes

  # The sentence that says what is missing, or nil when nothing is.
  sig { params(env: T::Hash[String, T.nilable(String)], production: T::Boolean).returns(T.nilable(String)) }
  def self.config_problem(env, production:)
    return nil unless production
    return nil if present?(env['COMEALS_STAGING']) || present?(env['LOCAL_PRODUCTION'])

    missing = []
    missing << "RAILS_DB_POOL=#{MIN_POOL}" if env['RAILS_DB_POOL'].to_i < MIN_POOL
    missing << 'SOLID_QUEUE_IN_PUMA=true' unless present?(env['SOLID_QUEUE_IN_PUMA'])
    return nil if missing.empty?

    "This release needs config vars the app does not have: #{missing.join(', ')}. " \
      'Without them live updates and the nightly jobs do not run (lib/deploy_config_check.rb). ' \
      "Run: heroku config:set #{missing.join(' ')} -a #{APP}  and deploy again. " \
      'The previous release is still serving.'
  end

  # The process kinds with no fresh heartbeat, as a sentence, or nil when
  # every kind is alive.
  sig { params(alive_kinds: T::Array[String]).returns(T.nilable(String)) }
  def self.process_problem(alive_kinds)
    dead = PROCESS_KINDS - alive_kinds
    return nil if dead.empty?

    "Solid Queue is not fully running: no heartbeat in the last #{HEARTBEAT_WITHIN.inspect} from " \
      "#{dead.join(', ')}. Live updates and the nightly jobs depend on it. Check SOLID_QUEUE_IN_PUMA is set " \
      "and read the dyno's boot log (heroku logs -a #{APP} | grep SolidQueue)."
  end

  sig { void }
  def self.verify_config!
    problem = config_problem(ENV.to_h, production: Rails.env.production?)
    raise problem if problem
  end

  sig { void }
  def self.verify_processes!
    alive = SolidQueue::Process.where(last_heartbeat_at: HEARTBEAT_WITHIN.ago..).distinct.pluck(:kind)
    problem = process_problem(alive)
    raise problem if problem
  end

  sig { params(value: T.nilable(String)).returns(T::Boolean) }
  def self.present?(value)
    !value.to_s.strip.empty?
  end
  private_class_method :present?
end

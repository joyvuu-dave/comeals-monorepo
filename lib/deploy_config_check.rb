# typed: true
# frozen_string_literal: true

# Refuse a production release that is missing the config var this code
# needs, and check afterwards that Solid Queue is really running.
#
# Since 2026-09-15 every live update is a Solid Queue job (ADR 0007), and
# the nightly jobs run from config/recurring.yml. Both need Solid Queue's
# supervisor, which runs on its own dyno (`worker: bin/jobs` in the
# Procfile). It forks a dispatcher, a worker and a scheduler, and each of
# those processes has its own pool of RAILS_DB_POOL connections and uses
# more than one at once (the poll, the heartbeat, a running job), so
# RAILS_DB_POOL has to be at least 4. The var is not in git.
#
# So the Procfile's release phase runs `deploy:verify_config` before the
# migration. A release phase that exits non-zero is not deployed: Heroku
# keeps the previous release serving, on both deploy paths (bin/deploy
# and the weekly promote in .github/workflows/deploy.yml). And after the
# deploy, `deploy:verify_solid_queue` checks that every Solid Queue
# process has a fresh heartbeat, because the worker dyno can be scaled to
# 0 or fail to start.
#
# Staging (COMEALS_STAGING) and a laptop running the production
# environment (LOCAL_PRODUCTION, bin/prod) are not held to this:
# bin/staging-rehearsal sets the pool on staging itself before it pushes,
# and a laptop has no Heroku config at all.
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

    return nil if env['RAILS_DB_POOL'].to_i >= MIN_POOL

    "This release needs a config var the app does not have: RAILS_DB_POOL=#{MIN_POOL}. " \
      'Without it the jobs on the worker dyno run out of database connections (lib/deploy_config_check.rb). ' \
      "Run: heroku config:set RAILS_DB_POOL=#{MIN_POOL} -a #{APP}  and deploy again. " \
      'The previous release is still serving.'
  end

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
  def self.verify_config!
    problem = config_problem(ENV.to_h, production: Rails.env.production?)
    raise problem if problem
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

  sig { params(value: T.nilable(String)).returns(T::Boolean) }
  def self.present?(value)
    !value.to_s.strip.empty?
  end
  private_class_method :present?
end

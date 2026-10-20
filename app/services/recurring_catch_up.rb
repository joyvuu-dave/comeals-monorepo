# typed: true
# frozen_string_literal: true

require 'fugit'

# Runs, at process boot, every recurring job whose last successful run is
# older than its most recent scheduled time.
#
# Heroku restarts every dyno once a day, and Solid Queue does not replay a
# schedule tick that happened while nothing was running. So a job due in
# the restart minute would simply not run that day. This closes that gap:
# when the process comes up, each job in config/recurring.yml is compared
# with job_runs, and any that missed its last tick is enqueued now. Because
# every RecurringJob is "make it so", running late is the same as running
# on time. Called from config/puma.rb when SOLID_QUEUE_IN_PUMA is set.
class RecurringCatchUp
  def self.call(now: Time.current)
    new(now).call
  end

  def initialize(now)
    @now = now
  end

  # Returns the job classes it enqueued.
  #
  # config/puma.rb runs this after boot with no rescue around it, so an
  # error that left here would end the web process and take the site
  # down. A job that is not queued here runs at its next tick, so each
  # error is reported to Bugsnag instead and the rest go on.
  def call
    due.select { |job_class| enqueue(job_class) }
  rescue StandardError => e
    report(e, 'all')
    []
  end

  # The recurring jobs whose last success predates their last scheduled tick.
  def due
    recurring = tasks.filter_map do |task|
      job_class = task[:class].constantize
      [job_class, task[:schedule]] if job_class < RecurringJob
    end
    last_successes = JobRun.last_success_at(recurring.map { |job_class, _schedule| job_class.run_name })

    recurring.filter_map do |job_class, schedule|
      last_tick = Fugit.parse(schedule).previous_time(@now).to_t
      last_success = last_successes[job_class.run_name]
      job_class if last_success.nil? || last_success < last_tick
    end
  end

  private

  # Active Job answers false, with no error, when the adapter refuses a
  # job (ActiveJob::Enqueuing#enqueue), so that is reported too.
  def enqueue(job_class)
    return true if job_class.perform_later

    report(RuntimeError.new("#{job_class.name} was not queued"), job_class.name)
    false
  rescue StandardError => e
    report(e, job_class.name)
    false
  end

  def report(error, job)
    Rails.error.report(error, handled: true, severity: :error, context: { job: job })
  end

  def tasks
    config = Rails.application.config_for(:recurring)
    config.values.select { |task| task.is_a?(Hash) && task[:class].present? }
  end
end

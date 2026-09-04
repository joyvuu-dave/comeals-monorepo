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
  def call
    due.each(&:perform_later)
  end

  # The recurring jobs whose last success predates their last scheduled tick.
  def due
    tasks.filter_map do |task|
      job_class = task[:class].constantize
      next unless job_class < RecurringJob

      last_tick = Fugit.parse(task[:schedule]).previous_time(@now).to_t
      last_success = JobRun.last_success_at(job_class.run_name)
      job_class if last_success.nil? || last_success < last_tick
    end
  end

  private

  def tasks
    config = Rails.application.config_for(:recurring)
    config.values.select { |task| task.is_a?(Hash) && task[:class].present? }
  end
end

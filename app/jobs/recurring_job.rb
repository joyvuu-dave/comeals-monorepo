# typed: true
# frozen_string_literal: true

# The base of every scheduled job. Three things every recurring job gets:
#
# 1. A run record. Every perform writes a JobRun (ok or failed, with the
#    error), so what ran and when is a database row, not a log line.
# 2. A healthchecks.io ping (Healthcheck.monitor), so a job that stops
#    running is noticed from outside the app.
# 3. One runner at a time. limits_concurrency keys on the class, so two
#    supervisors during a deploy overlap cannot run the same job at once.
#
# And one rule every subclass must keep: `perform` is "make it so", never
# "do the nightly thing". It compares what should be true with what is and
# converges, so it can run at any time, twice, late, or after a crash and
# reach the same state. That is what lets the schedule, the boot-time
# catch-up (RecurringCatchUp), and a person all trigger the same job.
#
# Subclasses set HEALTHCHECK to their healthchecks.io slug and implement
# `run`, which may return a hash of details to store on the run record.
class RecurringJob < ApplicationJob
  limits_concurrency key: ->(*) { name }, duration: 1.hour

  # A run that reads rows and writes rows can be refused by PostgreSQL for
  # a conflict with another transaction (ADR 0005): the balance refresh
  # against a settlement's own refresh, a rotation's new meals against a
  # sign-up. The refusal is transient by definition, and every job here is
  # safe to run twice by contract, so the run is tried again — inside the
  # ping and the run record, which see one run. Five tries, a quarter
  # second apart at first, the way SettleAndNotify waits: nobody is
  # waiting on a job's answer.
  CONFLICT_ATTEMPTS = 5
  CONFLICT_BASE_DELAY = 0.25

  # The name a run is recorded under, and the key config/recurring.yml uses.
  def self.run_name
    T.must(name).delete_suffix('Job').underscore
  end

  def perform
    started_at = Time.current
    details = T.let(nil, T.untyped)
    self.class.const_get(:HEALTHCHECK).then do |slug|
      Healthcheck.monitor(slug) do
        details = RetryOnConflict.call(attempts: CONFLICT_ATTEMPTS, base_delay: CONFLICT_BASE_DELAY) { run }
      end
    end
    record(started_at, outcome: 'ok', details: details)
  # Exception, not StandardError: this is a record of what happened, and it
  # must not depend on what kind of error it was. A SIGTERM from a dyno
  # restart (Interrupt), a missing constant (LoadError), or a forgotten
  # `run` (NotImplementedError) are all runs that did not finish, and the
  # row should say so. The error is re-raised at once, so nothing here
  # swallows it.
  rescue Exception => e # rubocop:disable Lint/RescueException -- recorded and re-raised at once
    record(started_at, outcome: 'failed', error: "#{e.class}: #{e.message}")
    raise
  end

  # Every subclass defines this. It is here so the base class names the
  # contract, and so a subclass that forgets it fails with a clear message.
  def run
    raise NotImplementedError, "#{self.class.name} must define #run"
  end

  private

  def record(started_at, outcome:, details: nil, error: nil)
    JobRun.create!(name: self.class.run_name, started_at: started_at, finished_at: Time.current,
                   outcome: outcome, details: details.is_a?(Hash) ? details : {}, error: error)
  end
end

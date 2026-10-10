# typed: true
# frozen_string_literal: true

# Email every cook in a settlement. Runs after the settlement has committed,
# outside any request: the paced sender pauses between messages, so with
# many cooks this takes longer than a web request may (#71).
#
# Safe to run twice. Each send writes a MailDelivery row, and a run mails
# only the cooks without one, so a job that stopped part way (dyno restart,
# the per-run cap) picks up where it stopped when Solid Queue runs it
# again. One run per reconciliation at a time, so two workers cannot mail
# the same cook at once. The reconciliations:send_cooking_slot_email task
# queues this job instead of sending, so this limit covers it too.
class NotifyCooksJob < ApplicationJob
  MAILER = 'reconciliation_notify_email'

  # Raised at the end of a run in which a send failed, so that retry_on
  # below runs the job again. Each failed send was already reported on
  # its own (MailDeliveryFailure).
  class SendsFailed < StandardError; end

  # How long to wait before each new try after a run with a failed send.
  # A mail server that is down for a few minutes, or an hour, should not
  # cost a cook the mail until the next night. After the last of these
  # the job ends without an error, and SendMissedCookMailJob tries again
  # each night for a week.
  RETRY_WAITS = [5.minutes, 30.minutes, 2.hours].freeze

  limits_concurrency key: ->(reconciliation) { reconciliation.id }, duration: 1.hour

  # Queued at once, inside the caller's transaction, never held back
  # until the commit. SettleAndNotify queues this job in the settlement's
  # own transaction, so the job row commits or rolls back with the
  # settlement. False is ActiveJob's default in Rails 8.1; it is written
  # here so a change of default cannot turn the queueing back into a
  # write after the commit.
  self.enqueue_after_transaction_commit = false

  retry_on SendsFailed, attempts: RETRY_WAITS.size + 1,
                        wait: ->(executions) { RETRY_WAITS.fetch(executions - 1) } do |job, error|
    Rails.logger.warn("#{MAILER}: #{error.message}. Tried #{job.executions} times; " \
                      'SendMissedCookMailJob tries again each night.')
  end

  # The cooks of this settlement who can get this mail: everyone with a
  # bill in it who has an email address. A retired resident, a child, or
  # someone who cannot cook may have none (Resident#email_presence), and a
  # retired cook can still have a bill here. Mail to an empty address
  # raises ArgumentError, which is not a delivery error, so one such cook
  # used to stop the whole run.
  def self.recipients(reconciliation)
    reconciliation.cooks.where.not(residents: { email: nil }).distinct
  end

  # For each of these settlements (a relation) that has a cook still owed
  # this mail, how many cooks: { reconciliation_id => count }. Owed means
  # a recipient as above with no MailDelivery row about that settlement.
  # One query for the whole set, for SendMissedCookMailJob.
  def self.cooks_owed(reconciliations)
    delivered = MailDelivery.where(mailer: MAILER, about_type: Reconciliation.polymorphic_name)
                            .where('mail_deliveries.about_id = meals.reconciliation_id')
                            .where('mail_deliveries.resident_id = bills.resident_id')
    Bill.joins(:meal, :resident)
        .where(meals: { reconciliation_id: reconciliations })
        .where.not(residents: { email: nil })
        .where(delivered.arel.exists.not)
        .group('meals.reconciliation_id')
        .distinct.count('bills.resident_id')
  end

  def perform(reconciliation)
    log_cooks_without_email(reconciliation)

    cooks = MailDelivery.not_yet_sent(self.class.recipients(reconciliation), mailer: MAILER, about: reconciliation)
    result = PacedDelivery.deliver(
      cooks, mailer: MAILER,
             after_send: ->(cook) { MailDelivery.record!(mailer: MAILER, about: reconciliation, resident: cook) }
    ) { |cook| ReconciliationMailer.reconciliation_notify_email(cook, reconciliation) }

    # The new try after a failed send also mails anyone the cap left out,
    # so it comes first.
    if result.failed.positive?
      raise SendsFailed, "#{result.failed} cook #{'email'.pluralize(result.failed)} not sent " \
                         "for reconciliation ##{reconciliation.id}"
    end

    # Over the cap: the rest are still owed a mail. Ask for another run
    # rather than waiting for a person to notice.
    self.class.perform_later(reconciliation) if result.skipped.positive?
  end

  private

  # One line for each cook the mail cannot reach, so a cook who says "I
  # never got it" can be found in the log. Not a Bugsnag report: a cook
  # with no address is allowed, and nothing is broken.
  def log_cooks_without_email(reconciliation)
    reconciliation.cooks.where(residents: { email: nil }).distinct.pluck(:id).each do |id|
      Rails.logger.info("#{MAILER}: not sent to resident ##{id}, who has no email address " \
                        "(reconciliation ##{reconciliation.id})")
    end
  end
end

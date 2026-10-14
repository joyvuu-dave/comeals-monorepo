# typed: true
# frozen_string_literal: true

# Email the common house what each person owes or is owed in a settlement
# (ADR 0011 rule 9, ReconciliationMailer#common_house_collection_email).
# SettleAndNotify queues it in the settlement's own transaction, next to
# the cook mail (NotifyCooksJob), so a saved settlement always has it
# queued and a rolled-back one never sends it.
#
# Sent once. The send writes a MailDelivery row with no resident, because
# the address is the common house's, not a person's. A run that finds the
# row sends nothing, so a retry, the nightly SendMissedSettlementMailJob
# and the rake task can all queue it without sending a second copy. One
# run per settlement at a time, so two workers cannot both send it.
class CommonHouseMailJob < ApplicationJob
  MAILER = 'common_house_collection_email'

  # Raised when the send failed, so that retry_on below runs the job
  # again. The failure was already reported (MailDeliveryFailure).
  class SendFailed < StandardError; end

  # The same waits as the cook mail: a mail server that is down for a few
  # minutes, or an hour, should not hold the email until the next night.
  RETRY_WAITS = NotifyCooksJob::RETRY_WAITS

  limits_concurrency key: ->(reconciliation) { reconciliation.id }, duration: 1.hour

  # Queued at once, inside the settlement's transaction, like
  # NotifyCooksJob: the job row commits or rolls back with the settlement.
  self.enqueue_after_transaction_commit = false

  retry_on SendFailed, attempts: RETRY_WAITS.size + 1,
                       wait: ->(executions) { RETRY_WAITS.fetch(executions - 1) } do |job, error|
    Rails.logger.warn("#{MAILER}: #{error.message}. Tried #{job.executions} times; " \
                      'SendMissedSettlementMailJob tries again each night.')
  end

  # The settlements among `reconciliations` (a relation) whose common
  # house email has not gone out.
  def self.not_sent(reconciliations)
    sent = MailDelivery.where(mailer: MAILER, about_type: Reconciliation.polymorphic_name, resident_id: nil)
    reconciliations.where.not(id: sent.select(:about_id))
  end

  def perform(reconciliation)
    return unless self.class.not_sent(Reconciliation.where(id: reconciliation.id)).exists?

    result = PacedDelivery.deliver(
      [reconciliation], mailer: MAILER,
                        recipient: ->(_reconciliation) { ReconciliationMailer::COMMON_HOUSE },
                        after_send: ->(sent) { MailDelivery.record!(mailer: MAILER, about: sent, resident: nil) }
    ) { |about| ReconciliationMailer.common_house_collection_email(about) }
    return unless result.failed.positive?

    raise SendFailed, "the common house email was not sent for reconciliation ##{reconciliation.id}"
  end
end

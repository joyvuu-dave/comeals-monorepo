# frozen_string_literal: true

# Email every cook in a settlement. Runs after the settlement has committed,
# outside any request: the paced sender pauses between messages, so with
# many cooks this takes longer than a web request may (#71).
#
# Safe to run twice. Each send writes a MailDelivery row, and a run mails
# only the cooks without one, so a job that stopped part way (dyno restart,
# the per-run cap) picks up where it stopped when Solid Queue runs it
# again. One run per reconciliation at a time, so two workers cannot mail
# the same cook at once.
class NotifyCooksJob < ApplicationJob
  MAILER = 'reconciliation_notify_email'

  limits_concurrency key: ->(reconciliation) { reconciliation.id }, duration: 1.hour

  def perform(reconciliation)
    cooks = MailDelivery.not_yet_sent(reconciliation.cooks.distinct, mailer: MAILER, about: reconciliation)
    result = PacedDelivery.deliver(
      cooks, mailer: MAILER,
             after_send: ->(cook) { MailDelivery.record!(mailer: MAILER, about: reconciliation, resident: cook) }
    ) { |cook| ReconciliationMailer.reconciliation_notify_email(cook, reconciliation) }

    # Over the cap: the rest are still owed a mail. Ask for another run
    # rather than waiting for a person to notice.
    self.class.perform_later(reconciliation) if result.skipped.positive?
    result
  end
end

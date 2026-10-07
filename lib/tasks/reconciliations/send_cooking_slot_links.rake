# frozen_string_literal: true

namespace :reconciliations do
  desc 'Queue the mail to each cook of the latest reconciliation who has not had it yet.'
  task send_cooking_slot_email: :environment do
    r = Reconciliation.last
    abort 'There is no reconciliation yet, so there are no cooks to mail.' if r.nil?

    # Queued, not sent here. NotifyCooksJob is the job that mails the cooks
    # after every settlement, and Solid Queue runs one of them per
    # reconciliation at a time. If this task sent the mail itself, a run
    # while that job was sending would mail the same cook twice. The job
    # mails only the cooks with no MailDelivery row for this mail about
    # this reconciliation, and queues itself again when the per-run cap
    # stops it. The Solid Queue worker must be running to send it.
    NotifyCooksJob.perform_later(r)
    Rails.logger.info("Cooks' Reconciliation Email: queued NotifyCooksJob for reconciliation ##{r.id}. " \
                      'It mails each cook who has not had this mail about it yet.')
  end
end

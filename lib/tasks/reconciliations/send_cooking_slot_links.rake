# frozen_string_literal: true

namespace :reconciliations do
  desc "Send links to each cook's bills for given reconciliation period."
  task send_cooking_slot_email: :environment do
    start_time = Time.current

    r = Reconciliation.last

    result = PacedDelivery.deliver(r.unique_cooks, mailer: 'reconciliation_notify_email') do |cook|
      ReconciliationMailer.reconciliation_notify_email(cook, r)
    end
    Rails.logger.info("Cooks' Reconciliation Email: #{result.sent} sent, #{result.failed} failed, " \
                      "#{result.skipped} over the cap")

    total_time = Time.current - start_time
    Rails.logger.info("Cooks' Reconciliation Email task Complete in #{total_time}s.")
  end
end

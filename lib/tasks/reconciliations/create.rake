# frozen_string_literal: true

namespace :reconciliations do
  desc 'Create a new reconciliation, assign unreconciled meals, recompute balances.'
  task create: :environment do
    start_time = Time.current

    community = Community.instance

    # Cutoff is yesterday: a meal from a day that is not yet over must not be
    # settled — its receipt and attendance are not final (issue #3).
    cutoff = Date.yesterday

    # No pre-check: Reconciliation#must_settle_at_least_one_meal already
    # refuses an empty sweep, reading the same eligible_meals scope that
    # Settlement#assign_meals uses. A second copy of that predicate here could
    # drift — and had (it lacked the distinct and the today exclusion).
    begin
      reconciliation = Settlement.run!(cutoff: cutoff, community: community)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.info(
        "reconciliations:create skipping #{community.name} — #{e.record.errors.full_messages.to_sentence}"
      )
      next
    end

    Rails.logger.info(
      "Reconciliation ##{reconciliation.id} created for #{community.name}: #{reconciliation.number_of_meals} meals"
    )

    Rake::Task['billing:recalculate'].invoke
    Rake::Task['billing:recalculate'].reenable

    reconciliation.unique_cooks.each do |cook|
      ReconciliationMailer.reconciliation_notify_email(cook, reconciliation).deliver_now
    rescue *MAIL_DELIVERY_ERRORS => e
      MailDeliveryFailure.report(e, mailer: 'reconciliation_notify_email', recipient: cook.email)
    end

    total_time = Time.current - start_time
    Rails.logger.info("reconciliations:create completed in #{total_time.round(2)}s")
  end
end

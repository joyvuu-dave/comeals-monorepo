# frozen_string_literal: true

namespace :reconciliations do
  desc 'Create a new reconciliation, assign unreconciled meals, recompute balances.'
  task create: :environment do
    start_time = Time.current
    community = Community.instance

    # Yesterday, always: a meal from a day that is not over is never settled.
    # Reconciliation#must_settle_at_least_one_meal refuses an empty sweep,
    # reading the same scope Settlement#assign_meals claims, so there is no
    # pre-check here — the refusal arrives as RecordInvalid.
    begin
      reconciliation = SettleAndNotify.call(cutoff: Date.yesterday, community: community)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.info(
        "reconciliations:create skipping #{community.name} — #{e.record.errors.full_messages.to_sentence}"
      )
      next
    end

    total_time = Time.current - start_time
    Rails.logger.info(
      "Reconciliation ##{reconciliation.id} created for #{community.name}: " \
      "#{reconciliation.number_of_meals} meals, in #{total_time.round(2)}s"
    )
  end
end

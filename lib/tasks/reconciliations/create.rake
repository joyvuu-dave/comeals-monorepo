# frozen_string_literal: true

namespace :reconciliations do
  desc 'Create a new reconciliation, assign unreconciled meals, recompute balances.'
  task create: :environment do
    start_time = Time.current
    community = Community.instance

    # The community's yesterday, always: a meal from a day that is not over
    # for the people who ate it is never settled. Not Date.yesterday — this
    # task runs in the app time zone, which need not be the community's.
    # Reconciliation#must_settle_at_least_one_meal refuses an empty sweep,
    # reading the same scope Settlement#assign_meals claims, so there is no
    # pre-check here — the refusal arrives as RecordInvalid.
    begin
      settlement = SettleAndNotify.call(cutoff: community.yesterday, community: community)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.info(
        "reconciliations:create skipping #{community.name} — #{e.record.errors.full_messages.to_sentence}"
      )
      next
    rescue Settlement::Contested => e
      # A reconciler settled from the app at the same moment and claimed
      # the meals first. The period is settled; nothing is left to do.
      Rails.logger.info(
        "reconciliations:create skipping #{community.name} — another settlement claimed the meals first " \
        "(#{e.message})"
      )
      next
    end

    # The count the settlement read inside its transaction: a query here,
    # after the commit, could fail and make the task exit 1 for a period
    # that is settled.
    total_time = Time.current - start_time
    Rails.logger.info(
      "Reconciliation ##{settlement.reconciliation.id} created for #{community.name}: " \
      "#{settlement.meal_count} meals, in #{total_time.round(2)}s"
    )
  end
end

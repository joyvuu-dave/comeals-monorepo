# frozen_string_literal: true

# Settling a period, as a person means it: settle, refresh the running
# balances, tell the cooks. One entry point for the nightly rake task and
# the API, so the two cannot drift.
#
#   SettleAndNotify.call(cutoff: Date.yesterday)   # => the Reconciliation
#
# Raises ActiveRecord::RecordInvalid when there is nothing to settle or the
# cutoff is not in the past (nothing was written), and Settlement::Contested
# or ActiveRecord::TransactionRollbackError when another writer got there
# first after the retries (nothing was written either). Mail failures are
# reported (MailDeliveryFailure) and never raised: the settlement is
# committed by then, and a lost email is fixable; a lost settlement is not.
# The mails go through PacedDelivery (one SMTP session, a pause between
# messages, a per-run cap), so a settlement with thirty cooks cannot trip
# Gmail the way the broadcasts did in July 2026.
class SettleAndNotify
  def self.call(cutoff:, community: Community.instance)
    # Only the settlement is retried. The recalculation and the mails run
    # after it has committed, so retrying past that point would settle the
    # next period by mistake (or fail because there is nothing left).
    reconciliation = RetryOnConflict.call { Settlement.run!(cutoff: cutoff, community: community) }

    BalanceRecalculation.call(community: community)
    notify_cooks(reconciliation)
    reconciliation
  end

  # One SMTP session, paced, capped — see PacedDelivery.
  def self.notify_cooks(reconciliation)
    PacedDelivery.deliver(reconciliation.unique_cooks, mailer: 'reconciliation_notify_email') do |cook|
      ReconciliationMailer.reconciliation_notify_email(cook, reconciliation)
    end
  end

  private_class_method :notify_cooks
end

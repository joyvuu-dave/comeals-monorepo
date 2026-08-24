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

  def self.notify_cooks(reconciliation)
    reconciliation.unique_cooks.each do |cook|
      ReconciliationMailer.reconciliation_notify_email(cook, reconciliation).deliver_now
    rescue *MAIL_DELIVERY_ERRORS => e
      MailDeliveryFailure.report(e, mailer: 'reconciliation_notify_email', recipient: cook.email)
    end
  end

  private_class_method :notify_cooks
end

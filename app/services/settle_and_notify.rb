# typed: strict
# frozen_string_literal: true

# Settling a period, as a person means it: settle, refresh the running
# balances, tell the cooks. One entry point for the nightly rake task, the
# API, and the admin form, so the three cannot drift.
#
#   SettleAndNotify.call(cutoff: community.yesterday)   # => the Reconciliation
#
# Raises ActiveRecord::RecordInvalid when there is nothing to settle or the
# cutoff is not in the past (nothing was written), and Settlement::Contested
# or ActiveRecord::TransactionRollbackError when another writer got there
# first after the retries (nothing was written either).
#
# The cook mail is a job (NotifyCooksJob), not part of this call. The
# settlement and the balance refresh are a handful of queries; the mail is
# one paced SMTP session with a pause per cook, which can take longer than
# a web request is allowed (#71). Enqueuing happens after the settlement
# has committed, so a rolled-back settlement never mails anyone.
class SettleAndNotify
  extend T::Sig

  sig { params(cutoff: Date, community: Community).returns(Reconciliation) }
  def self.call(cutoff:, community: Community.instance)
    # Only the settlement is retried. The recalculation and the mails run
    # after it has committed, so retrying past that point would settle the
    # next period by mistake (or fail because there is nothing left).
    reconciliation = RetryOnConflict.call { Settlement.run!(cutoff: cutoff, community: community) }

    BalanceRecalculation.call(community: community)
    NotifyCooksJob.perform_later(reconciliation)
    reconciliation
  end
end

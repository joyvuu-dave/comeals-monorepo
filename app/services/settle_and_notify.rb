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

  # A settlement is a batch job, not a request: nobody is waiting on the
  # answer at five in the morning, and a conflict means someone is editing
  # yesterday's meal right now. So it tries ten times, waiting from a
  # quarter second up to about a minute, a few minutes in all. The request
  # defaults (three tries, milliseconds apart) lost three in a row in two of
  # five write storms (spec/db/meal_write_storm_spec.rb, 2026-09-09), and a
  # lost settlement is a failed task and a period that waits a day.
  ATTEMPTS = T.let(10, Integer)
  BASE_DELAY = T.let(0.25, Float)

  sig { params(cutoff: Date, community: Community).returns(Reconciliation) }
  def self.call(cutoff:, community: Community.instance)
    # Only the settlement is retried. The recalculation and the mails run
    # after it has committed, so retrying past that point would settle the
    # next period by mistake (or fail because there is nothing left).
    reconciliation = RetryOnConflict.call(attempts: ATTEMPTS, base_delay: BASE_DELAY) do
      Settlement.run!(cutoff: cutoff)
    end

    refresh_balances(community)
    NotifyCooksJob.perform_later(reconciliation)
    reconciliation
  end

  # The running balances, after the settlement has committed. A conflict
  # here (the nightly refresh running at the same moment) is tried again;
  # one that does not go away is reported and skipped, because raising now
  # would tell the caller "nothing was saved" about a settlement that is
  # in the database, and skip the cook mail. The balances are a cache the
  # nightly job rebuilds (CLAUDE.md, money rule 6).
  sig { params(community: Community).void }
  def self.refresh_balances(community)
    RetryOnConflict.call(attempts: ATTEMPTS, base_delay: BASE_DELAY) do
      BalanceRecalculation.call(community: community)
    end
  rescue ActiveRecord::TransactionRollbackError => e
    Rails.error.report(e, handled: true, severity: :error, context: { step: 'balance refresh after settlement' })
  end
end

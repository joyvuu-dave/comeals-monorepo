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

  # How long to keep trying when another writer gets there first. The
  # caller picks, because the answer depends on who is waiting.
  class Retries < T::Struct
    const :attempts, Integer
    const :base_delay, Float
  end

  # The nightly task's. Nobody is waiting on the answer at five in the
  # morning, and a conflict means someone is editing yesterday's meal
  # right now, so it is worth waiting out: ten tries, from a quarter
  # second, doubling. Three quick tries lost three in a row in two of five
  # write storms (spec/db/meal_write_storm_spec.rb, 2026-09-09), and a lost
  # settlement is a failed task and a period that waits a day.
  BATCH = T.let(Retries.new(attempts: 10, base_delay: 0.25), Retries)

  # A person's, for the settle button. The same three quick tries every
  # other write in a request gets (RetryOnConflict's defaults), and then a
  # 409 that says to try again.
  #
  # BATCH cannot be used here. Its ten tries sleep between two and four
  # minutes all told, and the web dyno serves one request at a time
  # (config/puma.rb), so a contested settlement would hold the only thread
  # and stop the app for everyone — while Heroku's router gave up at 30
  # seconds and showed the reconciler an error for a settlement that was
  # still running. Found by bin/storm at 128 clients, 2026-09-11.
  REQUEST = T.let(
    Retries.new(attempts: RetryOnConflict::MAX_ATTEMPTS, base_delay: RetryOnConflict::BASE_DELAY), Retries
  )

  sig { params(cutoff: Date, community: Community, retries: Retries).returns(Reconciliation) }
  def self.call(cutoff:, community: Community.instance, retries: BATCH)
    # Only the settlement is retried. The recalculation and the mails run
    # after it has committed, so retrying past that point would settle the
    # next period by mistake (or fail because there is nothing left).
    reconciliation = RetryOnConflict.call(attempts: retries.attempts, base_delay: retries.base_delay) do
      Settlement.run!(cutoff: cutoff)
    end

    refresh_balances(community, retries)
    NotifyCooksJob.perform_later(reconciliation)
    reconciliation
  end

  # The running balances, after the settlement has committed. A conflict
  # here (the nightly refresh running at the same moment) is tried again;
  # one that does not go away is reported and skipped, because raising now
  # would tell the caller "nothing was saved" about a settlement that is
  # in the database, and skip the cook mail. The balances are a cache the
  # nightly job rebuilds (CLAUDE.md, money rule 6).
  # The caller's patience again: this runs in the same request, so it must
  # not spend the minutes the settlement was allowed to.
  sig { params(community: Community, retries: Retries).void }
  def self.refresh_balances(community, retries)
    RetryOnConflict.call(attempts: retries.attempts, base_delay: retries.base_delay) do
      BalanceRecalculation.call(community: community)
    end
  rescue ActiveRecord::TransactionRollbackError => e
    Rails.error.report(e, handled: true, severity: :error, context: { step: 'balance refresh after settlement' })
  end
end

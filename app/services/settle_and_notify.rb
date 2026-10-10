# typed: strict
# frozen_string_literal: true

# Settling a period, as a person means it: settle, queue the cook mail,
# clear the caches, refresh the running balances. One entry point for
# the nightly rake task, the API, and the admin form, so the three cannot
# drift.
#
#   SettleAndNotify.call(cutoff: community.yesterday)   # => the Settlement
#
# Raises ActiveRecord::RecordInvalid when there is nothing to settle or the
# cutoff is not in the past (nothing was written), and Settlement::Contested
# or ActiveRecord::TransactionRollbackError when another writer got there
# first after the retries (nothing was written either). Two more raise
# from inside the transaction when the cook mail job was not queued, so
# nothing was written for them too: MailNotQueued, when the queue adapter
# refused the job, and SolidQueue::Job::EnqueueError, when the database
# refused its row for a reason that is not a conflict. Nobody rescues
# those two, so the API and the admin form answer them with a 500.
#
# Nothing after the commit raises. The settlement and the job that mails
# its cooks commit together, in one transaction, and the callers answer
# from what that transaction read (Settlement#claimed_meals, the
# reconciliation row). So an error after the commit can never reach a
# rescue that tells the person "Nothing was saved" about a settlement
# that is in the database. Each step after the commit reports its own
# error and the next step still runs (after_commit_step).
#
# The cook mail is a job (NotifyCooksJob), not part of this call. The
# settlement and the balance refresh are a handful of queries; the mail is
# one paced SMTP session with a pause per cook, which can take longer than
# a web request is allowed (#71). The job is queued inside the
# settlement's transaction: Solid Queue keeps its jobs in this database,
# so the job row commits with the settlement or rolls back with it. A
# rolled-back settlement never mails anyone, and a saved one always has
# its mail queued, even when the process stops right after the commit.
class SettleAndNotify
  extend T::Sig

  # How long to keep trying when another writer gets there first. The
  # caller picks, because the answer depends on who is waiting.
  class Retries < T::Struct
    const :attempts, Integer
    const :base_delay, Float
  end

  # Raised inside the settlement's transaction when the cook mail job was
  # not queued, so the settlement rolls back: a saved settlement always
  # has its mail queued.
  class MailNotQueued < StandardError; end

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

  sig { params(cutoff: Date, community: Community, retries: Retries).returns(Settlement) }
  def self.call(cutoff:, community: Community.instance, retries: BATCH)
    # Only the settlement and its mail job are retried. The cache clear
    # and the recalculation run after the commit, so retrying past that
    # point would settle the next period by mistake (or fail because there
    # is nothing left).
    settlement = RetryOnConflict.call(attempts: retries.attempts, base_delay: retries.base_delay) do
      settle_and_queue_mail(cutoff)
    end

    after_commit_step('cache clear after settlement') { settlement.forget_cached_meals }
    after_commit_step('balance refresh after settlement') { refresh_balances(community, retries) }
    settlement
  end

  # One transaction: the settlement, then the job that mails its cooks.
  # Settlement.settle!'s own transaction joins this one, so both commit
  # at the same moment. NotifyCooksJob must be queued at once, not after
  # the commit (its enqueue_after_transaction_commit is false), or the
  # job would be a write after the commit again. perform_later answers
  # false, and raises nothing, when an adapter refuses a job through
  # ActiveJob's own EnqueueError; that rolls the settlement back too.
  sig { params(cutoff: Date).returns(Settlement) }
  def self.settle_and_queue_mail(cutoff)
    Reconciliation.transaction do
      Settlement.settle!(cutoff: cutoff).tap do |settlement|
        unless NotifyCooksJob.perform_later(settlement.reconciliation)
          raise MailNotQueued, 'The cook mail could not be queued, so nothing was settled.'
        end
      end
    end
  end

  # A step after the commit. Its error is reported, never raised: the
  # settlement is in the database, and a raise would reach a rescue that
  # answers "Nothing was saved" (the API's 409, the admin form's alert)
  # or fail the nightly task for a period that is settled. Every error,
  # not only conflicts: a lock wait that ran out, a statement cancelled
  # by statement_timeout (the refresh's DEFERRABLE read waits against
  # it), or a bug. Each step has a backup: the calendar months are keyed
  # by a version read from the rows (CLAUDE.md, rule 8), a client that
  # missed a push fetches again when it reconnects, and the balances are
  # a cache the nightly job rebuilds (money rule 6).
  sig { params(step: String, blk: T.proc.void).void }
  def self.after_commit_step(step, &blk) # rubocop:disable Naming/BlockForwarding -- the sig above has to name the block
    yield
  rescue StandardError => e
    Rails.error.report(e, handled: true, severity: :error, context: { step: step })
  end

  # The running balances, after the settlement has committed. A conflict
  # here (the nightly refresh running at the same moment) is tried again;
  # one that does not go away reaches after_commit_step and is reported.
  # The caller's patience again: this runs in the same request, so it must
  # not spend the minutes the settlement was allowed to.
  sig { params(community: Community, retries: Retries).void }
  def self.refresh_balances(community, retries)
    RetryOnConflict.call(attempts: retries.attempts, base_delay: retries.base_delay) do
      BalanceRecalculation.call(community: community)
    end
  end
  private_class_method :settle_and_queue_mail, :after_commit_step, :refresh_balances
end

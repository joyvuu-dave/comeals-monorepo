# typed: strict
# frozen_string_literal: true

# Runs a block, and runs it again if PostgreSQL refused it for a conflict
# with another transaction.
#
# At SERIALIZABLE, PostgreSQL may refuse a transaction that would otherwise
# have committed, because letting it commit would produce a result no serial
# order of transactions could produce. The refusal is not a bug and there is
# nothing to fix in the statement — the documented response is to run the
# whole transaction again. Deadlocks work the same way. Both arrive as
# ActiveRecord::TransactionRollbackError.
#
# Two rules make this safe to use, and both are enforced rather than
# documented and hoped for.
#
# It only retries at the outermost transaction. Once a transaction has been
# refused, every later statement in it fails too, so re-running the block
# inside the same transaction cannot work — it would just fail again with
# "current transaction is aborted". If a transaction is already open, this
# re-raises immediately and lets whoever owns that transaction decide.
#
# The block must be safe to run twice. In this app that means no email, no
# Pusher, no HTTP call before the commit. That holds today because every
# such side effect is in an after_commit callback or outside the transaction
# entirely, which is what makes retry cheap here at all. Anything added
# inside a retried block has to keep that property. A job queued inside
# the block keeps it: Solid Queue writes the job as a row in the block's
# own transaction, so a refused try takes its job with it
# (SettleAndNotify queues the cook mail this way).
#
# A conflict can also arrive wrapped. Solid Queue turns every database
# error from its enqueue into SolidQueue::Job::EnqueueError, a plain
# StandardError, with the database error as its cause. That is still the
# database refusing this block, so it is retried the same way, and when
# the tries run out the conflict itself is raised, so a caller's rescue
# of TransactionRollbackError still answers it. Until 2026-10-09 a
# refused push enqueue (LiveUpdate.push) was dropped after one try.
#
# Retries are reported through Rails.error so they are counted rather than
# merely survived. A retry that works and a retry that fires constantly look
# identical from the outside, and the second one is a problem.
class RetryOnConflict
  extend T::Sig

  # The defaults are a request's: a person is waiting, and after three
  # quick tries a 409 that says "try again" is the honest answer. A batch
  # job can afford more (SettleAndNotify passes its own).
  MAX_ATTEMPTS = T.let(3, Integer)

  # Doubling, from 10ms, with jitter. The jitter matters: two transactions
  # that conflicted once and then wait the same length of time are likely to
  # conflict again on the retry.
  BASE_DELAY = T.let(0.01, Float)

  # Returns whatever the block returns on the attempt that succeeds.
  sig do
    type_parameters(:Result)
      .params(attempts: Integer, base_delay: Float, blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def self.call(attempts: MAX_ATTEMPTS, base_delay: BASE_DELAY, &blk)
    # Already inside a transaction, so a retry here cannot succeed. See
    # above. This is also what a spec running under transactional fixtures
    # hits, which is why the fault injection lives in the non-transactional
    # specs.
    return yield if ActiveRecord::Base.connection.transaction_open?

    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::TransactionRollbackError, SolidQueue::Job::EnqueueError => e
      conflict = conflict_in(e)
      raise unless conflict
      raise conflict if attempt >= attempts

      Rails.error.report(
        conflict,
        handled: true,
        severity: :warning,
        context: { attempt: attempt, max_attempts: attempts }
      )

      sleep(base_delay * (2**(attempt - 1)) * (1 + Kernel.rand))
      retry
    end
  end

  # The conflict an error is, or carries: the error itself, or the cause
  # of an EnqueueError. Nil for an enqueue refused for another reason.
  sig do
    params(error: T.any(ActiveRecord::TransactionRollbackError, SolidQueue::Job::EnqueueError))
      .returns(T.nilable(ActiveRecord::TransactionRollbackError))
  end
  def self.conflict_in(error)
    return error if error.is_a?(ActiveRecord::TransactionRollbackError)

    cause = error.cause
    cause if cause.is_a?(ActiveRecord::TransactionRollbackError)
  end
  private_class_method :conflict_in
end

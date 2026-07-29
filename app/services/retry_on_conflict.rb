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
# inside a retried block has to keep that property.
#
# Retries are reported through Rails.error so they are counted rather than
# merely survived. A retry that works and a retry that fires constantly look
# identical from the outside, and the second one is a problem.
class RetryOnConflict
  MAX_ATTEMPTS = 3

  # Doubling, from 10ms, with jitter. The jitter matters: two transactions
  # that conflicted once and then wait the same length of time are likely to
  # conflict again on the retry.
  BASE_DELAY = 0.01

  def self.call
    # Already inside a transaction, so a retry here cannot succeed. See
    # above. This is also what a spec running under transactional fixtures
    # hits, which is why the fault injection lives in the non-transactional
    # specs.
    return yield if ActiveRecord::Base.connection.transaction_open?

    attempts = 0
    begin
      attempts += 1
      yield
    rescue ActiveRecord::TransactionRollbackError => e
      raise if attempts >= MAX_ATTEMPTS

      Rails.error.report(
        e,
        handled: true,
        severity: :warning,
        context: { attempt: attempts, max_attempts: MAX_ATTEMPTS }
      )

      sleep(BASE_DELAY * (2**(attempts - 1)) * (1 + Kernel.rand))
      retry
    end
  end
end

# typed: strict
# frozen_string_literal: true

# Runs a block inside one read-only database snapshot.
#
# Use this for a job that reads many rows across several queries and must
# see all of them as they were at one instant. The plain default
# (READ COMMITTED) takes a fresh snapshot per statement, so a write that
# commits between two queries makes the job's answer match no real state
# of the ledger.
#
# The transaction is opened as SERIALIZABLE READ ONLY DEFERRABLE. Each
# of the three words does a separate job:
#
#   SERIALIZABLE  One snapshot for the whole transaction, and the result
#                 is guaranteed to match some serial order of the
#                 transactions around it. REPEATABLE READ also gives one
#                 snapshot, but only SERIALIZABLE rules out the anomalies
#                 that a pure snapshot still allows.
#
#   READ ONLY     The block may not write. This is a real guard, not a
#                 hint: an INSERT or UPDATE inside the block is refused by
#                 PostgreSQL, so a later edit cannot quietly turn a
#                 consistent read into a half-committed write.
#
#   DEFERRABLE    The transaction waits at the start until PostgreSQL can
#                 hand it a snapshot that is already free of serialization
#                 anomalies. Having waited, it can never abort with a
#                 serialization failure (40001), and it never causes any
#                 other transaction to abort either. This is the whole
#                 reason to prefer SERIALIZABLE READ ONLY DEFERRABLE over
#                 REPEATABLE READ for a batch read: the stronger guarantee
#                 costs no retry logic.
#
# DEFERRABLE only takes effect on a SERIALIZABLE READ ONLY transaction.
# All three must be set together or the guarantee is not there.
#
# The wait is not free — it lasts until the read-write SERIALIZABLE
# transactions that are already running finish. Since 2026-08-02 the whole
# app runs at SERIALIZABLE (config/database.yml sets it per session; ADR
# 0005), so this block waits for in-flight writers instead of racing them.
# That is the behavior we want for a nightly batch job: a short wait at
# the start buys a snapshot that can never abort.
#
# Rails has no API for READ ONLY or DEFERRABLE, only for the isolation
# level, so the other two modes are set with a second SET TRANSACTION.
# Both must run before the transaction's first real query; PostgreSQL
# refuses them after that.
class SnapshotRead
  extend T::Sig

  # Returns whatever the block returns, so a caller can read several
  # values inside the snapshot and hand them out in one line.
  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def self.call(&blk) # rubocop:disable Naming/BlockForwarding -- the sig above has to name the block
    connection = ActiveRecord::Base.connection

    # A transaction is already open. In production this does not happen —
    # the callers are rake tasks that start with no transaction. In the
    # test suite it is the transactional-fixtures wrapper, which has
    # already run queries, so SET TRANSACTION would be refused. Rails
    # ignores an isolation hint in exactly this case for exactly this
    # reason; match it and run the block as it is. What that costs is
    # real and worth naming: specs that run inside the fixture
    # transaction do not exercise the snapshot. The one that does is
    # spec/tasks/billing_recalculate_snapshot_spec.rb, which turns
    # transactional fixtures off for that reason.
    return yield if connection.transaction_open?

    ActiveRecord::Base.transaction(isolation: :serializable) do
      connection.execute('SET TRANSACTION READ ONLY, DEFERRABLE')
      yield
    end
  end
end

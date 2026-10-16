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
#                 PostgreSQL. If a later code change adds a write here, it
#                 raises an error; it cannot turn a consistent read into a
#                 half-committed write.
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
# The wait reaches across databases: PostgreSQL keeps one list of
# serializable transactions for the whole instance, so a read-write
# transaction in another database on the same server holds this one up
# too (checked 2026-09-13 with two psql sessions on two databases: the
# deferrable one waited the full length of the other's transaction).
# Under mutant, six workers in six databases never stop writing, and a
# sibling's hung mutation can hold a transaction open for two minutes,
# so the read hit the 10 s statement timeout and the unmutated code
# failed its own examples. Two worktrees running tests at once did the
# same to each other. So `config.x.snapshot_reads_deferrable` is off in
# the test environment (config/environments/test.rb) and on everywhere
# else (config/application.rb). Without DEFERRABLE the read can fail
# with a serialization error, and every caller retries one: RecurringJob
# for the nightly jobs, SettleAndNotify for the refresh after a
# settlement.
#
# Production is the case the test environment cannot show. Heroku's
# essential plans put many customers' databases on one server (855 of
# them on ours on 2026-10-11), so the nightly jobs wait for any of their
# SERIALIZABLE writers too. None of them used SERIALIZABLE when measured,
# 20 sampled starts waited about 0 ms, and none of the 70 nightly runs
# since 2026-08-02 failed. But the wait is
# not ours to control, and under the 10 s statement timeout a 10 s write
# by a stranger would fail the night's job. So a caller that nobody is
# waiting on passes `wait_limit:` (NIGHTLY_WAIT for the two nightly jobs),
# and the wait gets that long while the reads after it keep the 10 s
# limit. The refresh after a settlement runs inside a person's request,
# so it passes nothing and keeps 10 s for the wait too.
#
# Rails has no API for READ ONLY or DEFERRABLE, only for the isolation
# level, so the other two modes are set with a second SET TRANSACTION.
# Both must run before the transaction's first real query; PostgreSQL
# refuses them after that.
class SnapshotRead
  extend T::Sig

  # How long a nightly job may wait for its snapshot. Long enough for a
  # stranger's slow write on the shared server to finish, and well inside
  # the hour that RecurringJob's limits_concurrency allows a run.
  NIGHTLY_WAIT = T.let(5.minutes, ActiveSupport::Duration)

  # Returns whatever the block returns, so a caller can read several
  # values inside the snapshot and hand them out in one line.
  sig do
    type_parameters(:Result)
      .params(wait_limit: T.nilable(ActiveSupport::Duration), blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def self.call(wait_limit: nil, &blk)
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
      deferrable = ', DEFERRABLE' if Rails.configuration.x.snapshot_reads_deferrable
      connection.execute("SET TRANSACTION READ ONLY#{deferrable}")
      take_snapshot(connection, wait_limit) if wait_limit
      yield
    end
  end

  # Takes the transaction's snapshot now, with wait_limit as the statement
  # timeout, then puts the old timeout back for the block's reads. SHOW and
  # SET take no snapshot, so the wait happens at the SELECT and nowhere
  # before it.
  sig { params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter, wait_limit: ActiveSupport::Duration).void }
  def self.take_snapshot(connection, wait_limit)
    statement_limit = connection.select_value('SHOW statement_timeout')
    connection.execute("SET LOCAL statement_timeout = '#{wait_limit.to_i}s'")
    connection.execute('SELECT 1')
    connection.execute("SET LOCAL statement_timeout = #{connection.quote(statement_limit)}")
  end
  private_class_method :take_snapshot
end

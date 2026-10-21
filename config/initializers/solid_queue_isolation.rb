# typed: false
# frozen_string_literal: true

# Solid Queue's own bookkeeping runs at READ COMMITTED. Everything else,
# every job's perform and every job the app queues, stays SERIALIZABLE
# (ADR 0005 decision 10, which records this one exception and why).
#
# "Bookkeeping" is the work Solid Queue does on its own threads to keep
# its records in the solid_queue_* tables: a process writing its
# heartbeat, registering and removing itself, a worker claiming jobs and
# marking a job finished or failed, giving back a job's limits_concurrency
# semaphore and letting the next blocked job go, the dispatcher moving due
# jobs to ready and deleting expired semaphores, and the scheduler saving
# its task list and queueing a recurring task. At SERIALIZABLE these
# cancel each other several times an hour, and a worker's poll can also
# cancel an app transaction that queues a job
# (spec/db/solid_queue_bookkeeping_race_spec.rb,
# spec/db/solid_queue_process_rows_race_spec.rb).
#
# How. Each method on the list below is wrapped. When it is called with no
# transaction open, the wrapper opens one, at READ COMMITTED, with
# `SolidQueue::Record.transaction(isolation: :read_committed)`, and runs
# the method inside it. A transaction the method opens itself then joins
# that one, and a `requires_new` one becomes a savepoint. Neither asks for
# a level of its own, so Rails has nothing to refuse. When the method is
# called inside a transaction that is already open, the wrapper does
# nothing and the method joins that transaction at its level: PostgreSQL
# cannot change the level of an open transaction.
#
# Until 2026-10-20 the wrapper used ActiveRecord.with_transaction_isolation_level
# instead. That gives the level to every transaction Rails opens on the
# thread, savepoints too, and Rails refuses a level on a savepoint. So the
# scheduler queued no recurring job at all, and a job that raised stayed
# claimed (spec/config/initializers/solid_queue_isolation_savepoint_spec.rb).
#
# Nothing on the list runs a job's perform or any app code. A job runs in
# ClaimedExecution#execute, which is not wrapped. A job the app queues
# goes through SolidQueue::Job.enqueue and the Job's own callbacks, which
# are not wrapped either: inside an app transaction they join it, and
# with no transaction open Rails opens one at the session's SERIALIZABLE.
# That includes Semaphore.wait, which the enqueue of a limits_concurrency
# job calls: it always runs inside the Job's create, so it is not wrapped.
#
# Wrapping a method in one transaction joins every transaction it used to
# run into one. For each method below, the comment says how many it ran
# before (a bare statement counts as one), and why one is safe. Where one
# is not safe, a smaller piece is wrapped instead:
#
#   - ClaimedExecution#finalize is not wrapped. It marks a job finished or
#     failed in one transaction, and only after that commits does it give
#     the job's semaphore back and let the next blocked job go. Solid
#     Queue keeps those apart on purpose, so a failure in the second part
#     cannot undo the first. So the three parts are wrapped one by one:
#     #unless_already_finalized, Semaphore::Proxy#signal and
#     BlockedExecution.release_one.
#   - RecurringTask#enqueue is not wrapped. It rescues the error a second
#     scheduler gets when the same run is already recorded
#     (RecurringExecution::AlreadyRecorded). Inside an outer transaction
#     that rescue would come before the rollback, and the duplicate job
#     would be committed. RecurringExecution.record, which queues the job
#     and records the run, is wrapped instead; the error leaves it, so its
#     transaction rolls back as before.
#   - BlockedExecution.unblock is not wrapped. It lets go one blocked job
#     for each of up to batch_size keys, each in its own transaction. In
#     one transaction it would hold every key's semaphore lock until the
#     last one, taken in key order: "CommonHouseMailJob/7" before
#     "NotifyCooksJob/7". The app queues a settlement's two mail jobs in
#     the other order (SettleAndNotify, SendMissedSettlementMailJob), so
#     the two could deadlock. Each release_one is wrapped instead.
#   - Dispatcher::Maintenance#sweep_stalled_batches is not wrapped.
#     Batch#finish relies on raising ActiveRecord::Rollback inside its own
#     transaction, which only rolls back when that transaction is the
#     outer one. The app makes no batches, so the sweep only reads empty
#     tables.
#
# What still runs at SERIALIZABLE on Solid Queue's threads: single reads
# made outside any transaction, in loops whose steps each have their own
# transaction above. Wrapping the loop would join its steps. They are the
# supervisor's read of dead processes (Process.prune), its reads of the
# jobs a dead or missing process held (ClaimedExecution.fail_all_with,
# Supervisor::Maintenance#release_claimed_jobs_by), the dispatcher's two
# reads before it lets blocked jobs go (BlockedExecution.unblock), and the
# reads of the task list and of batches. A read can make PostgreSQL cancel
# a transaction only together with SERIALIZABLE transactions that write
# the same rows; RetryOnConflict retries those on the app's side.
#
# The list is the gem's 1.7.0 code. Boot fails if a method on it is gone,
# and spec/config/initializers/solid_queue_isolation_spec.rb checks each
# one is wrapped. After a Solid Queue upgrade, read the gem again for
# transactions and statements on its own threads, and for each method on
# the list check that its count below still holds.
module SolidQueueIsolation
  # [class, method, :class_method or :instance_method]
  BOOKKEEPING = [
    # One transaction before (create!).
    ['SolidQueue::Process', :register, :class_method],
    # One before (with_lock).
    ['SolidQueue::Process', :heartbeat, :instance_method],
    # One for its own row, with the release of each job it had claimed
    # (after_destroy). A supervisor also removes any rows its threads left,
    # each in its own transaction. Now one: a failure keeps every row,
    # and the next supervisor's prune removes them later.
    ['SolidQueue::Process', :deregister, :instance_method],
    # A read of paused queues, then one transaction for each queue
    # relation ("*" is one). Now one. The worker gets the claimed jobs
    # only after the claim returns, so a rollback cannot undo a job that
    # is running.
    ['SolidQueue::ReadyExecution', :claim, :class_method],
    # One (finish or fail the job, remove the claim), from finalize and
    # from a process giving its claims back.
    ['SolidQueue::ClaimedExecution', :unless_already_finalized, :instance_method],
    # One bare UPDATE: give a semaphore back after finalize.
    ['SolidQueue::Semaphore::Proxy', :signal, :instance_method],
    # One bare UPDATE for each concurrency limit. Called only inside a
    # transaction today (discarding jobs); wrapped so it stays at READ
    # COMMITTED if a caller changes.
    ['SolidQueue::Semaphore::Proxy', :signal_all, :class_method],
    # One: let one blocked job of a key go.
    ['SolidQueue::BlockedExecution', :release_one, :class_method],
    # One.
    ['SolidQueue::ScheduledExecution', :dispatch_next_batch, :class_method],
    # A SELECT and a DELETE for each batch of expired semaphores, all bare.
    # Now one. Deleting an expired semaphore twice is the same as once,
    # and there are few: a key for each limited job class and settlement.
    ['SolidQueue::Dispatcher::Maintenance', :expire_semaphores, :instance_method],
    # One: queue the job and record the run, or neither.
    ['SolidQueue::RecurringExecution', :record, :class_method],
    # Two bare statements at the scheduler's start: delete tasks gone from
    # config/recurring.yml, then upsert the rest. Now one, so a second
    # scheduler sees the old list or the new one.
    ['SolidQueue::Scheduler::RecurringSchedule', :persist_static_tasks, :instance_method]
  ].freeze

  # Marks the modules this file prepends, so a spec can find them.
  module Wrapper; end

  def self.read_committed(&)
    if SolidQueue::Record.with_connection(&:transaction_open?)
      yield
    else
      SolidQueue::Record.transaction(isolation: :read_committed, &)
    end
  end

  def self.target(class_name, kind)
    klass = class_name.constantize
    kind == :class_method ? klass.singleton_class : klass
  end

  def self.wrapped?(target, name)
    target.instance_method(name).owner.is_a?(Wrapper)
  end

  def self.apply
    BOOKKEEPING.each do |(class_name, name, kind)|
      target = target(class_name, kind)
      private_method = target.private_method_defined?(name)
      unless private_method || target.method_defined?(name)
        raise "Solid Queue no longer has #{class_name} #{kind} #{name}; " \
              'see config/initializers/solid_queue_isolation.rb'
      end
      next if wrapped?(target, name)

      target.prepend(wrapper_for(name, private_method))
    end
  end

  def self.wrapper_for(name, private_method)
    Module.new do
      extend Wrapper

      define_method(name) do |*args, **kwargs, &block|
        SolidQueueIsolation.read_committed { super(*args, **kwargs, &block) }
      end
      private name if private_method
    end
  end
end

# to_prepare, because Solid Queue's models are reloaded in development
# and a reloaded class has lost the wrapper.
Rails.application.config.to_prepare { SolidQueueIsolation.apply }

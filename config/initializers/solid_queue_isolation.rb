# typed: false
# frozen_string_literal: true

# Solid Queue's own bookkeeping runs at READ COMMITTED. Everything else,
# every job's perform and every job the app queues, stays SERIALIZABLE
# (ADR 0005, which records this one exception and why).
#
# "Bookkeeping" is the transactions Solid Queue opens on its own threads
# to keep its records in the solid_queue_* tables: a process writing its
# heartbeat, registering and removing itself, a worker claiming jobs and
# marking a job finished or failed (with the limits_concurrency semaphore
# it gives back and the blocked job it lets go), the dispatcher moving
# due jobs to ready and its concurrency maintenance, and the scheduler
# queueing a recurring task. At SERIALIZABLE these cancel each other
# several times an hour, and a worker's poll can also cancel an app
# transaction that queues a job (spec/db/solid_queue_bookkeeping_race_spec.rb,
# spec/db/solid_queue_process_rows_race_spec.rb).
#
# Each method below is wrapped in ActiveRecord.with_transaction_isolation_level,
# which sets the level of each transaction Rails opens inside it, on this
# thread only. None of them runs a job's perform or app code: a job runs
# in ClaimedExecution#execute, which is not wrapped, on a thread of the
# worker's pool, which this thread setting does not reach. Two limits:
#
#   - A wrapped method called inside a transaction that is already open
#     joins it at that transaction's level. PostgreSQL cannot change the
#     level of an open transaction, and Rails raises if asked to.
#   - A statement Solid Queue runs outside any transaction (the UPDATE
#     that gives back a semaphore, the DELETE of expired semaphores, the
#     reads before a prune) still runs at the session's SERIALIZABLE.
#     Rails applies the level only to transactions it opens.
#
# The list is the gem's 1.7.0 code. Boot fails if a method on it is gone,
# and spec/config/initializers/solid_queue_isolation_spec.rb checks each
# one is wrapped. After a Solid Queue upgrade, read the gem for new
# transactions on its own threads and add them here.
module SolidQueueIsolation
  # [class, method, :class_method or :instance_method]
  BOOKKEEPING = [
    ['SolidQueue::Process', :register, :class_method],
    ['SolidQueue::Process', :heartbeat, :instance_method],
    ['SolidQueue::Process', :deregister, :instance_method],
    ['SolidQueue::ReadyExecution', :claim, :class_method],
    ['SolidQueue::ClaimedExecution', :finalize, :instance_method],
    ['SolidQueue::ScheduledExecution', :dispatch_next_batch, :class_method],
    ['SolidQueue::Dispatcher::Maintenance', :expire_semaphores, :instance_method],
    ['SolidQueue::Dispatcher::Maintenance', :unblock_blocked_executions, :instance_method],
    ['SolidQueue::Dispatcher::Maintenance', :sweep_stalled_batches, :instance_method],
    ['SolidQueue::RecurringTask', :enqueue, :instance_method]
  ].freeze

  # Marks the modules this file prepends, so a spec can find them.
  module Wrapper; end

  def self.read_committed(&)
    if SolidQueue::Record.with_connection(&:transaction_open?)
      yield
    else
      ActiveRecord.with_transaction_isolation_level(:read_committed, &)
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

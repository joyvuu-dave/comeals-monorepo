# frozen_string_literal: true

require 'rails_helper'

# Found by bin/storm with STORM_SOLID_QUEUE=1, 2026-10-20: the first run
# with a real bin/jobs process. Until the fix the same day,
# config/initializers/solid_queue_isolation.rb set READ COMMITTED with
# ActiveRecord.with_transaction_isolation_level, which gives the level to
# every transaction opened inside it, a savepoint too. Rails refuses a
# level on a savepoint (ActiveRecord::TransactionIsolationError, "cannot
# set transaction isolation in a nested transaction"), so these steps
# raised whenever they opened one:
#
#   - the scheduler queueing a recurring task: Job#ready calls
#     create_or_find_by!. The schedule queued no job, on staging too;
#   - a worker removing itself while it holds a claimed job
#     (Process#deregister): giving the job back to the queue goes through
#     create_or_find_by!, inside the destroy. A stopped jobs process left
#     its row and its claim;
#   - the worker finishing a job that raised: the same requires_new,
#     inside the finish. The job stayed claimed instead of failed;
#   - the dispatcher moving a due job that has a concurrency limit from
#     scheduled to ready (ScheduledExecution.dispatch_next_batch): such a
#     job is moved one at a time, through create_or_find_by!. A
#     NotifyCooksJob retry waits there.
#
# Now the wrapper opens one explicit READ COMMITTED transaction, and the
# ones inside it join it or become savepoints with no level of their own.
# The dispatcher letting a blocked job go opens no savepoint; it is here
# so that stays true.
RSpec.describe 'config/initializers/solid_queue_isolation.rb, on steps that open a savepoint' do
  include_context 'with no test transaction'
  include_context 'with Solid Queue as the job adapter'

  it 'lets the scheduler queue a recurring task' do
    task = SolidQueue::RecurringTask.create!(key: 'refresh_balances', class_name: 'RefreshBalancesJob',
                                             schedule: '0 3 * * * UTC')

    queued = task.enqueue(at: Time.current.change(usec: 0))

    expect(queued).to be_truthy
    expect(SolidQueue::Job.where(class_name: 'RefreshBalancesJob').count).to eq(1)
    expect(SolidQueue::RecurringExecution.where(task_key: 'refresh_balances').count).to eq(1)
  end

  # RefreshBalancesJob allows one run at a time (RecurringJob), so the
  # second is blocked. The dispatcher looks only at blocked jobs whose
  # wait has run out, and lets one go when its semaphore is free.
  it 'lets the dispatcher release a blocked job once its semaphore is free' do
    RefreshBalancesJob.perform_later
    RefreshBalancesJob.perform_later
    expect(SolidQueue::BlockedExecution.count).to eq(1)
    SolidQueue::ReadyExecution.delete_all
    SolidQueue::Semaphore.delete_all
    SolidQueue::BlockedExecution.update_all(expires_at: 1.minute.ago)
    maintenance = SolidQueue::Dispatcher::Maintenance.new(1, 100, concurrency: true, batches: false)

    maintenance.send(:unblock_blocked_executions)

    expect(SolidQueue::BlockedExecution.count).to eq(0)
    expect(SolidQueue::ReadyExecution.count).to eq(1)
  end

  it 'lets a worker deregister while it holds a claimed job, and gives the job back to the queue' do
    process = SolidQueue::Process.register(kind: 'Worker', name: 'worker-test', pid: 1, hostname: 'test',
                                           metadata: {})
    LivePushJob.perform_later('meal-1', { message: 'meal updated' })
    job = SolidQueue::Job.sole
    job.ready_execution.destroy!
    SolidQueue::ClaimedExecution.create!(job: job, process_id: process.id)

    process.deregister

    expect(SolidQueue::Process.count).to eq(0)
    expect(SolidQueue::ClaimedExecution.count).to eq(0)
    expect(SolidQueue::ReadyExecution.sole.job_id).to eq(job.id)
  end

  it 'lets the worker record a job that raised as failed' do
    stub_const('FailingProbeJob', Class.new(ApplicationJob) { def perform = raise('probe failed') })
    FailingProbeJob.perform_later
    worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.01)
    worker.mode = :inline

    worker.start

    expect(SolidQueue::ClaimedExecution.count).to eq(0)
    expect(SolidQueue::FailedExecution.sole.error['message']).to eq('probe failed')
  end

  it 'lets the dispatcher move a due job with a concurrency limit to ready' do
    NotifyCooksJob.set(wait: 1.minute).perform_later(create(:reconciliation))
    SolidQueue::ScheduledExecution.update_all(scheduled_at: 1.second.ago)

    SolidQueue::ScheduledExecution.dispatch_next_batch(10)

    expect(SolidQueue::ScheduledExecution.count).to eq(0)
    expect(SolidQueue::ReadyExecution.joins(:job).where(job: { class_name: 'NotifyCooksJob' }).count).to eq(1)
  end

  # Found by bin/storm with STORM_SOLID_QUEUE=1 at 256 clients,
  # 2026-10-20. After a job with a concurrency limit finishes, the worker
  # gives its semaphore back with a single UPDATE outside any
  # transaction (ClaimedExecution#finalize, Semaphore.signal). The
  # wrapper sets the level only for transactions Rails opens, so that
  # UPDATE runs at the session's SERIALIZABLE, and PostgreSQL refused it
  # ("Canceled on identification as a pivot, during write"). The worker
  # thread reported "Error in thread"; the job was already finished, but
  # its semaphore was not given back, so the next run of that job waits
  # until the semaphore expires: an hour for every RecurringJob and for
  # NotifyCooksJob. Now Semaphore::Proxy#signal is on the initializer's
  # list, so the UPDATE has a READ COMMITTED transaction of its own.
  it 'gives back a finished job\'s semaphore at READ COMMITTED' do
    RefreshBalancesJob.perform_later
    stub_const('RefreshBalancesJob', Class.new(RecurringJob) do
      def self.name = 'RefreshBalancesJob'
      def perform = nil
    end)
    levels = []
    record = lambda do |*, payload|
      next unless payload[:sql].start_with?('UPDATE "solid_queue_semaphores"')

      levels << ActiveRecord::Base.connection.select_value('SHOW transaction_isolation')
    end
    worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.01)
    worker.mode = :inline

    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { worker.start }

    expect(SolidQueue::Job.sole.finished_at).to be_present
    expect(levels).to eq(['read committed'])
  end
end

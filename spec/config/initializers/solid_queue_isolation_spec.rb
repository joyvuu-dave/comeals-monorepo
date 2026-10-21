# frozen_string_literal: true

require 'rails_helper'

# config/initializers/solid_queue_isolation.rb runs Solid Queue's own
# bookkeeping at READ COMMITTED, and nothing else (ADR 0005). These
# examples pin both sides: each method on its list is still in the gem and
# wrapped, a wrapped method's transaction is READ COMMITTED, and a job's
# perform and a job queued by app code stay SERIALIZABLE.
# spec/db/solid_queue_bookkeeping_race_spec.rb and
# spec/db/solid_queue_process_rows_race_spec.rb show what the wrapping is for.
RSpec.describe 'config/initializers/solid_queue_isolation.rb' do
  def isolation_in_a_transaction
    ActiveRecord::Base.transaction { ActiveRecord::Base.connection.select_value('SHOW transaction_isolation') }
  end

  # A gem upgrade that renames or removes a method on the list fails here
  # (and at boot), instead of leaving that step at SERIALIZABLE with no error.
  it 'wraps every method on its list, and each one is still in the gem' do
    SolidQueueIsolation::BOOKKEEPING.each do |(class_name, name, kind)|
      method = SolidQueueIsolation.target(class_name, kind).instance_method(name)

      expect(method.owner).to be_a(SolidQueueIsolation::Wrapper), "#{class_name} #{name}"
      expect(method.super_method&.owner.to_s).to include('SolidQueue::'), "#{class_name} #{name}"
    end
  end

  it 'keeps a private method private' do
    expect(SolidQueue::ClaimedExecution.private_method_defined?(:unless_already_finalized)).to be(true)
    expect(SolidQueue::Scheduler::RecurringSchedule.private_method_defined?(:persist_static_tasks)).to be(true)
    expect(SolidQueue::Process.method_defined?(:heartbeat)).to be(true)
  end

  # Solid Queue keeps the finish of a job apart from what comes after it
  # (ClaimedExecution#finalize), so it is not on the list; its parts are.
  it 'leaves out the methods whose transactions must stay apart' do
    listed = SolidQueueIsolation::BOOKKEEPING.map { |(class_name, name, _kind)| [class_name, name] }

    expect(listed).not_to include(['SolidQueue::ClaimedExecution', :finalize],
                                  ['SolidQueue::RecurringTask', :enqueue],
                                  ['SolidQueue::BlockedExecution', :unblock],
                                  ['SolidQueue::Dispatcher::Maintenance', :sweep_stalled_batches])
  end

  it 'refuses to boot when a method on its list is gone from the gem' do
    stub_const('SolidQueueIsolation::BOOKKEEPING', [['SolidQueue::Process', :beat, :instance_method]])

    expect { SolidQueueIsolation.apply }.to raise_error(
      RuntimeError,
      'Solid Queue no longer has SolidQueue::Process instance_method beat; ' \
      'see config/initializers/solid_queue_isolation.rb'
    )
  end

  # Rails runs to_prepare again after a reload in development. A class that
  # was not reloaded keeps its wrapper and must not get a second one.
  it 'wraps each method once, however often it runs' do
    SolidQueueIsolation.apply

    wrappers = SolidQueue::Process.ancestors.count do |ancestor|
      ancestor.is_a?(SolidQueueIsolation::Wrapper) && ancestor.method_defined?(:heartbeat)
    end
    expect(wrappers).to eq(1)
  end

  describe 'outside a transaction' do
    include_context 'with no test transaction'

    it 'opens its transactions at READ COMMITTED, and only inside the wrapped call' do
      inside = SolidQueueIsolation.read_committed { isolation_in_a_transaction }

      expect(inside).to eq('read committed')
      expect(isolation_in_a_transaction).to eq('serializable')
    end

    # The real method: a heartbeat's own transaction.
    it "runs a process's heartbeat at READ COMMITTED" do
      process = SolidQueue::Process.register(kind: 'Worker', name: 'worker-test', pid: 1, hostname: 'test',
                                             metadata: {})
      seen = []
      record = lambda do |*, payload|
        next unless payload[:sql].start_with?('UPDATE "solid_queue_processes"')

        seen << ActiveRecord::Base.connection.select_value('SHOW transaction_isolation')
      end

      ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { process.heartbeat }

      expect(seen).to eq(['read committed'])
    end
  end

  # A real job, claimed and run by a real Solid Queue worker. The worker
  # runs inline: it works until no job is ready, then stops.
  describe 'a job run by Solid Queue' do
    include_context 'with no test transaction'
    include_context 'with Solid Queue as the job adapter'

    # The transaction level at each statement that matches, as
    # [statement, level] pairs.
    def levels_at(pattern, &)
      seen = Concurrent::Array.new
      record = lambda do |*, payload|
        next unless payload[:sql].match?(pattern)

        statement = payload[:sql][/\A(INSERT INTO|UPDATE) "\w+"/]
        seen << [statement, ActiveRecord::Base.connection.select_value('SHOW transaction_isolation')]
      end
      ActiveSupport::Notifications.subscribed(record, 'sql.active_record', &)
      seen.to_a
    end

    it "runs the job's perform at SERIALIZABLE, and the worker's own steps at READ COMMITTED" do
      in_perform = Concurrent::Array.new
      stub_const('IsolationProbeJob', Class.new(ApplicationJob) do
        define_method(:perform) do
          in_perform << ActiveRecord::Base.transaction do
            ActiveRecord::Base.connection.select_value('SHOW transaction_isolation')
          end
        end
      end)
      IsolationProbeJob.perform_later
      worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.01)
      worker.mode = :inline

      levels = levels_at(/\A(INSERT INTO "solid_queue_claimed_executions"|UPDATE "solid_queue_jobs")/) { worker.start }

      expect(in_perform).to eq(['serializable'])
      expect(levels).to eq([['INSERT INTO "solid_queue_claimed_executions"', 'read committed'],
                            ['UPDATE "solid_queue_jobs"', 'read committed']])
      expect(SolidQueue::Job.sole.finished_at).to be_present
    end

    # A job with limits_concurrency. When the worker finishes it, three
    # things happen, each in its own transaction (ClaimedExecution#finalize):
    # the job is marked finished, its semaphore is given back, and the next
    # blocked job of its key is let go. Each must be READ COMMITTED, and
    # none may share a transaction with another.
    def limited_job_pair
      stub_const('RefreshBalancesJob', Class.new(RecurringJob) do
        def self.name = 'RefreshBalancesJob'
        def perform = nil
      end)
      RefreshBalancesJob.perform_later
      RefreshBalancesJob.perform_later
      expect(SolidQueue::BlockedExecution.count).to eq(1)
    end

    def run_worker
      worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.01)
      worker.mode = :inline
      worker.start
    end

    it 'finishes a limited job, gives back its semaphore and lets the next one go, each in its own transaction' do
      limited_job_pair
      seen = Concurrent::Array.new
      finalize_statements = /\A(UPDATE "solid_queue_(jobs|semaphores)"|DELETE FROM "solid_queue_blocked_executions")/
      record = lambda do |*, payload|
        statement = payload[:sql][finalize_statements]
        next unless statement

        connection = ActiveRecord::Base.connection
        seen << [statement, connection.select_value('SHOW transaction_isolation'),
                 connection.select_value('SELECT txid_current()')]
      end

      ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { run_worker }

      # Finish, give back, then take the semaphore again for the blocked
      # job and remove its blocked row: the last two are one transaction.
      first_finish = seen.take(4)
      expect(first_finish.map(&:first)).to eq(['UPDATE "solid_queue_jobs"', 'UPDATE "solid_queue_semaphores"',
                                               'UPDATE "solid_queue_semaphores"',
                                               'DELETE FROM "solid_queue_blocked_executions"'])
      expect(first_finish.map(&:second)).to all(eq('read committed'))
      finish, give_back, release, release_again = first_finish.map(&:third)
      expect([finish, give_back, release].uniq.size).to eq(3)
      expect(release_again).to eq(release)
      expect(SolidQueue::Job.where(finished_at: nil).count).to eq(0)
    end

    # Solid Queue's own reason for keeping them apart: a failure while
    # letting the next job go must not undo a job that already ran. The
    # job stays finished, its semaphore is given back, and the blocked job
    # waits for the dispatcher, which lets it go once the semaphore is free.
    it 'keeps a finished job finished, and its semaphore given back, when letting the next job go fails' do
      limited_job_pair
      allow(SolidQueue::BlockedExecution).to receive(:ordered)
        .and_raise(ActiveRecord::StatementInvalid, 'release failed')
      allow(SolidQueue.on_thread_error).to receive(:call)

      run_worker

      expect(SolidQueue::Job.where.not(finished_at: nil).count).to eq(1)
      expect(SolidQueue::ClaimedExecution.count).to eq(0)
      expect(SolidQueue::Semaphore.sole.value).to eq(1)
      expect(SolidQueue::BlockedExecution.count).to eq(1)
      expect(SolidQueue.on_thread_error).to have_received(:call)
        .with(an_instance_of(ActiveRecord::StatementInvalid).and(having_attributes(message: 'release failed')))
    end

    # LiveUpdate's push after a commit and RecurringCatchUp queue jobs with
    # no transaction open. Rails opens one for the job's row at the
    # session's level, and the semaphore of a limited job is taken in it
    # (Semaphore.wait, which is not wrapped). App code stays SERIALIZABLE.
    it 'queues a limited job from app code with no transaction open at SERIALIZABLE, semaphore included' do
      stub_const('RefreshBalancesJob', Class.new(RecurringJob) { def self.name = 'RefreshBalancesJob' })

      enqueue_writes = /\A(INSERT INTO|UPDATE) "solid_queue_(jobs|semaphores|ready_executions|blocked_executions)"/
      levels = levels_at(enqueue_writes) do
        2.times { RefreshBalancesJob.perform_later }
      end

      expect(levels.map(&:first)).to include('INSERT INTO "solid_queue_semaphores"',
                                             'INSERT INTO "solid_queue_ready_executions"',
                                             'INSERT INTO "solid_queue_blocked_executions"')
      expect(levels.map(&:second).uniq).to eq(['serializable'])
    end

    # Why RecurringTask#enqueue is not wrapped. A second scheduler queueing
    # the same run finds it already recorded, and Solid Queue rescues that
    # inside #enqueue. In an outer transaction the rescue would come first
    # and the duplicate job would be committed.
    it 'queues a recurring run once at READ COMMITTED, and rolls back a second try at the same run' do
      task = SolidQueue::RecurringTask.create!(key: 'refresh_balances', class_name: 'RefreshBalancesJob',
                                               schedule: '0 3 * * * UTC')
      at = Time.current.change(usec: 0)

      levels = levels_at(/\AINSERT INTO "solid_queue_jobs"/) do
        task.enqueue(at: at)
        expect(task.enqueue(at: at)).to be(false)
      end

      expect(levels.map(&:second)).to eq(['read committed', 'read committed'])
      expect(SolidQueue::Job.count).to eq(1)
      expect(SolidQueue::RecurringExecution.count).to eq(1)
    end

    it 'queues a job from app code in the open transaction, at SERIALIZABLE, and rolls it back with it' do
      stub_const('IsolationProbeJob', Class.new(ApplicationJob) { def perform = nil })

      levels = levels_at(/\AINSERT INTO "solid_queue_jobs"/) do
        ActiveRecord::Base.transaction do
          IsolationProbeJob.perform_later
          raise ActiveRecord::Rollback
        end
      end

      expect(levels).to eq([['INSERT INTO "solid_queue_jobs"', 'serializable']])
      expect(SolidQueue::Job.count).to eq(0)
    end
  end

  # PostgreSQL cannot change the level of an open transaction, and Rails
  # raises when asked to. A wrapped call inside one joins it.
  it 'joins a transaction that is already open, at its level' do
    ActiveRecord::Base.transaction do
      expect(SolidQueueIsolation.read_committed { isolation_in_a_transaction }).to eq('serializable')
    end
  end
end

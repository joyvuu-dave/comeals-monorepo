# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/solid_queue_check')

# The heartbeat check that runs after a deploy. Live updates and the
# nightly jobs depend on the Solid Queue supervisor on the worker dyno.
RSpec.describe SolidQueueCheck do
  describe '.process_problem' do
    it 'is satisfied when every kind has a heartbeat' do
      expect(described_class.process_problem(%w[Supervisor Dispatcher Worker Scheduler])).to be_nil
    end

    it 'names the kinds without one' do
      problem = described_class.process_problem(%w[Supervisor Dispatcher])

      expect(problem).to include('Worker, Scheduler')
      expect(problem).not_to include('Supervisor,')
    end

    it 'names every kind when nothing is running, and says to look at the worker dyno' do
      expect(described_class.process_problem([])).to eq(
        'Solid Queue is not fully running: no heartbeat in the last 2 minutes from ' \
        'Supervisor, Dispatcher, Worker, Scheduler. Live updates and the nightly jobs depend on it. ' \
        'Check that the worker dyno runs (heroku ps -a comeals-monorepo) and read its log ' \
        '(heroku logs -a comeals-monorepo --dyno worker | grep SolidQueue).'
      )
    end
  end

  describe '.verify_processes!' do
    def register(kind, at:)
      SolidQueue::Process.create!(kind: kind, last_heartbeat_at: at, pid: 1, name: "#{kind.downcase}-1",
                                  hostname: 'dyno')
    end

    # The kinds as Solid Queue itself saves them. The supervisor's kind
    # names its mode, "Supervisor(async)" on the worker dyno, so a list
    # typed by hand ("Supervisor") passes here and fails on Heroku.
    def real_kinds
      supervisor = SolidQueue::AsyncSupervisor.new(SolidQueue::Configuration.new(mode: :async))
      [supervisor.kind, 'Dispatcher', 'Worker', 'Scheduler']
    end

    it 'passes when every kind has a heartbeat in the last two minutes' do
      real_kinds.each { |kind| register(kind, at: 1.minute.ago) }

      expect { described_class.verify_processes! }.not_to raise_error
    end

    it 'passes an async supervisor too' do
      supervisor = SolidQueue::AsyncSupervisor.new(SolidQueue::Configuration.new(mode: :async))
      [supervisor.kind, 'Dispatcher', 'Worker', 'Scheduler'].each { |kind| register(kind, at: 1.minute.ago) }

      expect { described_class.verify_processes! }.not_to raise_error
    end

    it 'fails when only the supervisor has no fresh heartbeat' do
      register(real_kinds.first, at: 3.minutes.ago)
      real_kinds.drop(1).each { |kind| register(kind, at: 1.minute.ago) }

      expect { described_class.verify_processes! }.to raise_error(/no heartbeat.*from Supervisor\./)
    end

    it 'fails on a kind whose last heartbeat is older than two minutes' do
      %w[Supervisor Dispatcher Scheduler].each { |kind| register(kind, at: 1.minute.ago) }
      register('Worker', at: 3.minutes.ago)

      expect { described_class.verify_processes! }.to raise_error(/no heartbeat.*from Worker/)
    end
  end

  # The heartbeat check passed on staging on 2026-10-20 while the
  # scheduler failed at every tick ("Error enqueuing recurring task ...
  # TransactionIsolationError"): a process can be alive and its work still
  # fail. This check queues a real recurring task through the scheduler's
  # own code (RecurringTask#enqueue) and waits until the worker has run it.
  describe '.verify_recurring_run!' do
    include_context 'with no test transaction'
    include_context 'with Solid Queue as the job adapter'

    let(:task_key) { SolidQueueCheck::RUN_CHECK_TASK }

    # The task as the scheduler saves it when it starts.
    def save_task
      config = Rails.application.config_for(:recurring).fetch(task_key.to_sym)
      SolidQueue::RecurringTask.from_configuration(task_key, **config).save!
    end

    # The worker on the dyno, in the spec: it runs every ready job, then stops.
    def run_worker(*)
      worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.01)
      worker.mode = :inline
      worker.start
    end

    it 'queues the task the way the scheduler does, waits for the worker to run it, and says how long it took' do
      save_task
      allow(GuestAddKey).to receive(:delete_expired).and_call_original

      result = described_class.verify_recurring_run!(sleeper: method(:run_worker))

      expect(result).to match(/\Athe worker ran #{task_key} \d+ s after it was queued\z/o)
      expect(GuestAddKey).to have_received(:delete_expired)
      expect(SolidQueue::Job.sole.finished_at).to be_present
      expect(SolidQueue::RecurringExecution.sole.task_key).to eq(task_key)
    end

    it 'fails when the scheduler has not saved its tasks' do
      expect { described_class.verify_recurring_run!(sleeper: method(:run_worker)) }
        .to raise_error(RuntimeError, /no recurring task #{task_key}.*the scheduler has not saved its tasks/o)
    end

    # What staging showed: the enqueue failed and Solid Queue only
    # reported it. The check names the error.
    it 'fails and names the error when the task cannot be queued' do
      save_task
      allow(SolidQueue::ReadyExecution).to receive(:create_or_find_by!)
        .and_raise(ActiveRecord::TransactionIsolationError, 'cannot set transaction isolation in a nested transaction')

      expect { described_class.verify_recurring_run!(sleeper: method(:run_worker)) }
        .to raise_error(RuntimeError, /could not queue #{task_key}: .*TransactionIsolationError: cannot set/o)
      expect(SolidQueue::Job.count).to eq(0)
    end

    it 'fails and names the error when the job fails' do
      save_task
      allow(GuestAddKey).to receive(:delete_expired).and_raise('cleanup broke')

      expect { described_class.verify_recurring_run!(sleeper: method(:run_worker)) }
        .to raise_error(RuntimeError, /#{task_key} failed on the worker: RuntimeError: cleanup broke/o)
    end

    it 'fails when the worker has not run it in time' do
      save_task
      waits = []

      expect { described_class.verify_recurring_run!(within: 3.seconds, sleeper: ->(seconds) { waits << seconds }) }
        .to raise_error(RuntimeError, /the worker did not run #{task_key} within 3 seconds; it is ready/o)
      expect(waits).to eq([SolidQueueCheck::POLL_EVERY, SolidQueueCheck::POLL_EVERY])
    end
  end
end

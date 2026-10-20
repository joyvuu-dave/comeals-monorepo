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
    # names its mode, "Supervisor(fork)" on the worker dyno, so a list
    # typed by hand ("Supervisor") passes here and fails on Heroku.
    def real_kinds
      supervisor = SolidQueue::ForkSupervisor.new(SolidQueue::Configuration.new(mode: :fork))
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
end

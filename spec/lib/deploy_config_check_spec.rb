# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/deploy_config_check')

# The release-phase check that keeps a production deploy from going live
# without the config vars Solid Queue needs, and the heartbeat check that
# runs after the deploy. Both live updates and the nightly jobs depend on
# the supervisor those vars start.
RSpec.describe DeployConfigCheck do
  describe '.config_problem' do
    let(:good) { { 'RAILS_DB_POOL' => '4', 'SOLID_QUEUE_IN_PUMA' => 'true' } }

    it 'is satisfied by a pool of four and the supervisor var' do
      expect(described_class.config_problem(good, production: true)).to be_nil
    end

    it 'names both vars, with the values to set, when neither is there' do
      problem = described_class.config_problem({}, production: true)

      expect(problem).to include('RAILS_DB_POOL=4, SOLID_QUEUE_IN_PUMA=true')
      expect(problem).to include('heroku config:set RAILS_DB_POOL=4 SOLID_QUEUE_IN_PUMA=true -a comeals-monorepo')
      expect(problem).to include('previous release is still serving')
    end

    it 'names only the pool when it is too small' do
      problem = described_class.config_problem(good.merge('RAILS_DB_POOL' => '2'), production: true)

      expect(problem).to include('RAILS_DB_POOL=4')
      expect(problem).not_to include('SOLID_QUEUE_IN_PUMA=true')
    end

    it 'names only the supervisor var when it is blank' do
      problem = described_class.config_problem(good.merge('SOLID_QUEUE_IN_PUMA' => ' '), production: true)

      expect(problem).to include('SOLID_QUEUE_IN_PUMA=true')
      expect(problem).not_to include('RAILS_DB_POOL')
    end

    it 'accepts a pool larger than four' do
      expect(described_class.config_problem(good.merge('RAILS_DB_POOL' => '8'), production: true)).to be_nil
    end

    it 'holds nothing against a non-production environment' do
      expect(described_class.config_problem({}, production: false)).to be_nil
    end

    it 'holds nothing against staging, which must not run jobs' do
      expect(described_class.config_problem({ 'COMEALS_STAGING' => '1' }, production: true)).to be_nil
    end

    it 'holds nothing against a laptop running the production environment' do
      expect(described_class.config_problem({ 'LOCAL_PRODUCTION' => '1' }, production: true)).to be_nil
    end
  end

  describe '.process_problem' do
    it 'is satisfied when every kind has a heartbeat' do
      expect(described_class.process_problem(%w[Supervisor Dispatcher Worker Scheduler])).to be_nil
    end

    it 'names the kinds without one' do
      problem = described_class.process_problem(%w[Supervisor Dispatcher])

      expect(problem).to include('Worker, Scheduler')
      expect(problem).not_to include('Supervisor,')
    end

    it 'names every kind when nothing is running' do
      expect(described_class.process_problem([])).to include('Supervisor, Dispatcher, Worker, Scheduler')
    end
  end

  describe '.verify_processes!' do
    def register(kind, at:)
      SolidQueue::Process.create!(kind: kind, last_heartbeat_at: at, pid: 1, name: "#{kind.downcase}-1",
                                  hostname: 'dyno')
    end

    it 'passes when every kind has a heartbeat in the last two minutes' do
      described_class::PROCESS_KINDS.each { |kind| register(kind, at: 1.minute.ago) }

      expect { described_class.verify_processes! }.not_to raise_error
    end

    it 'fails on a kind whose last heartbeat is older than two minutes' do
      %w[Supervisor Dispatcher Scheduler].each { |kind| register(kind, at: 1.minute.ago) }
      register('Worker', at: 3.minutes.ago)

      expect { described_class.verify_processes! }.to raise_error(/no heartbeat.*from Worker/)
    end
  end

  describe '.verify_config!' do
    it 'reads the process environment and the Rails environment' do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(ENV).to receive(:to_h).and_return({})

      expect { described_class.verify_config! }.to raise_error(/RAILS_DB_POOL=4, SOLID_QUEUE_IN_PUMA=true/)
    end

    it 'passes outside production' do
      expect { described_class.verify_config! }.not_to raise_error
    end
  end
end

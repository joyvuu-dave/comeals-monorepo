# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/deploy_config_check')

# The release-phase check that keeps a production deploy from going live
# without the database pool the jobs dyno needs, and the heartbeat check
# that runs after the deploy. Both live updates and the nightly jobs depend
# on the Solid Queue supervisor on the worker dyno.
RSpec.describe DeployConfigCheck do
  describe '.config_problem' do
    let(:good) { { 'RAILS_DB_POOL' => '4' } }

    # The jobs run on the worker dyno now (Procfile), so the var that
    # started them inside Puma is not needed and not asked for.
    it 'is satisfied by a pool of four alone' do
      expect(described_class.config_problem(good, production: true)).to be_nil
    end

    it 'names the pool, with the value to set, when it is not there' do
      problem = described_class.config_problem({}, production: true)

      expect(problem).to eq(
        'This release needs a config var the app does not have: RAILS_DB_POOL=4. ' \
        'Without it the jobs on the worker dyno run out of database connections ' \
        '(lib/deploy_config_check.rb). Run: heroku config:set RAILS_DB_POOL=4 -a comeals-monorepo  ' \
        'and deploy again. The previous release is still serving.'
      )
    end

    it 'names the pool when it is too small' do
      expect(described_class.config_problem({ 'RAILS_DB_POOL' => '2' }, production: true)).to include('RAILS_DB_POOL=4')
    end

    it 'accepts a pool larger than four' do
      expect(described_class.config_problem({ 'RAILS_DB_POOL' => '8' }, production: true)).to be_nil
    end

    it 'holds nothing against a non-production environment' do
      expect(described_class.config_problem({}, production: false)).to be_nil
    end

    it 'holds nothing against staging, where bin/staging-rehearsal sets the pool itself' do
      expect(described_class.config_problem({ 'COMEALS_STAGING' => '1' }, production: true)).to be_nil
    end

    it 'holds nothing against a laptop running the production environment' do
      expect(described_class.config_problem({ 'LOCAL_PRODUCTION' => '1' }, production: true)).to be_nil
    end

    # config/environments/production.rb reads the two vars with present?,
    # so a blank one does not make a staging app or a laptop there. It
    # must not excuse a release here either.
    it 'holds a release to the rule when COMEALS_STAGING or LOCAL_PRODUCTION is blank' do
      %w[COMEALS_STAGING LOCAL_PRODUCTION].product(['', ' ']).each do |name, blank|
        expect(described_class.config_problem({ name => blank }, production: true))
          .to include('RAILS_DB_POOL=4'), "#{name}=#{blank.inspect}"
      end
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

  describe '.verify_config!' do
    it 'reads the process environment and the Rails environment' do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(ENV).to receive(:to_h).and_return({})

      expect { described_class.verify_config! }.to raise_error(/does not have: RAILS_DB_POOL=4\./)
    end

    it 'passes a production release that has the pool' do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(ENV).to receive(:to_h).and_return({ 'RAILS_DB_POOL' => '4' })

      expect { described_class.verify_config! }.not_to raise_error
    end

    it 'passes outside production' do
      expect { described_class.verify_config! }.not_to raise_error
    end
  end
end

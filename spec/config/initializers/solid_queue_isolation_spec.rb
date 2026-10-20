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
    expect(SolidQueue::ClaimedExecution.private_method_defined?(:finalize)).to be(true)
    expect(SolidQueue::Process.method_defined?(:heartbeat)).to be(true)
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

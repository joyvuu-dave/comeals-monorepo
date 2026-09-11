# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RecurringJob do
  before { create(:community) }

  it 'records a successful run with the details the job returned, and pings healthchecks' do
    allow(Healthcheck).to receive(:ping)

    RefreshBalancesJob.perform_now

    run = JobRun.last
    expect(run.name).to eq('refresh_balances')
    expect(run.outcome).to eq('ok')
    expect(run.details).to eq('balances_written' => 0)
    expect(run.finished_at).to be >= run.started_at
    expect(Healthcheck).to have_received(:ping).with('billing-recalculate')
  end

  it 'records a failed run with the error, pings a failure, and re-raises' do
    allow(Healthcheck).to receive(:ping)
    allow(BalanceRecalculation).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

    expect { RefreshBalancesJob.perform_now }.to raise_error(ActiveRecord::StatementInvalid)

    run = JobRun.last
    expect(run.outcome).to eq('failed')
    expect(run.error).to eq('ActiveRecord::StatementInvalid: connection lost')
    expect(Healthcheck).to have_received(:ping).with('billing-recalculate', state: 'fail')
  end

  # These two errors are not StandardErrors, so a plain rescue would let
  # them through with no row and no ping.
  it 'records a failed run and pings fail when a subclass forgets to define run' do
    forgetful = Class.new(described_class) { const_set(:HEALTHCHECK, 'forgetful') }
    stub_const('ForgetfulJob', forgetful)
    allow(Healthcheck).to receive(:ping)

    expect { forgetful.perform_now }.to raise_error(NotImplementedError, 'ForgetfulJob must define #run')

    run = JobRun.last
    expect(run.name).to eq('forgetful')
    expect(run.outcome).to eq('failed')
    expect(run.error).to eq('NotImplementedError: ForgetfulJob must define #run')
    expect(Healthcheck).to have_received(:ping).with('forgetful', state: 'fail')
  end

  it 'records a run cut short by a signal, which is what a dyno restart sends' do
    allow(Healthcheck).to receive(:ping)
    allow(BalanceRecalculation).to receive(:call).and_raise(Interrupt)

    expect { RefreshBalancesJob.perform_now }.to raise_error(Interrupt)

    run = JobRun.last
    expect(run.outcome).to eq('failed')
    expect(run.error).to eq('Interrupt: Interrupt')
    expect(Healthcheck).to have_received(:ping).with('billing-recalculate', state: 'fail')
  end

  it 'names runs after the job class' do
    expect(RefreshBalancesJob.run_name).to eq('refresh_balances')
    expect(EnsureRotationsJob.run_name).to eq('ensure_rotations')
  end

  # A job that reads rows and writes rows can be refused by PostgreSQL for a
  # conflict with another transaction (ADR 0005): the balance refresh
  # against a settlement's own refresh, a rotation's meals against a
  # sign-up. The refusal is transient by definition and every recurring job
  # is safe to run twice by contract, so it is tried again, before the
  # run record and the ping, which see one run that went fine. Found by
  # spec/concurrency/request_storm_spec.rb and recycled_thread_spec.rb.
  describe 'when the run conflicts with another transaction' do
    include_context 'with no test transaction'

    before { create(:community) }

    it 'tries again, and records and pings one good run' do
      allow(Healthcheck).to receive(:ping)
      allow(RetryOnConflict).to receive(:sleep)
      attempts = 0
      allow(BalanceRecalculation).to receive(:call) do
        attempts += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if attempts < 3

        7
      end

      RefreshBalancesJob.perform_now

      expect(attempts).to eq(3)
      run = JobRun.last
      expect(run.outcome).to eq('ok')
      expect(run.details).to eq('balances_written' => 7)
      expect(JobRun.count).to eq(1)
      expect(Healthcheck).to have_received(:ping).with('billing-recalculate').once
    end

    it 'gives up after its attempts, and records and pings the failure' do
      allow(Healthcheck).to receive(:ping)
      allow(RetryOnConflict).to receive(:sleep)
      allow(BalanceRecalculation).to receive(:call).and_raise(ActiveRecord::SerializationFailure, 'conflict')

      expect { RefreshBalancesJob.perform_now }.to raise_error(ActiveRecord::SerializationFailure)

      expect(BalanceRecalculation).to have_received(:call).exactly(RecurringJob::CONFLICT_ATTEMPTS).times
      expect(JobRun.last.outcome).to eq('failed')
      expect(Healthcheck).to have_received(:ping).with('billing-recalculate', state: 'fail')
    end
  end
end

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
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RecurringCatchUp do
  include ActiveJob::TestHelper

  before { create(:community) }

  # 2026-08-24 12:00 UTC: refresh_balances (03:00) and verify_ledger (05:00)
  # and set_multipliers (11:00) have ticked today; ensure_rotations (22:30)
  # last ticked yesterday.
  let(:now) { Time.utc(2026, 8, 24, 12, 0) }

  def succeeded(job, at)
    JobRun.create!(name: job.run_name, started_at: at - 1.second, finished_at: at, outcome: 'ok')
  end

  it 'is due for every job that has never succeeded' do
    expect(described_class.new(now).due).to contain_exactly(RefreshBalancesJob, VerifyLedgerJob, SetMultipliersJob,
                                                            EnsureRotationsJob)
  end

  it 'is not due for a job that succeeded since its last tick, and due for one that missed it' do
    succeeded(RefreshBalancesJob, Time.utc(2026, 8, 24, 3, 0, 30))   # ran at today's tick
    succeeded(VerifyLedgerJob, Time.utc(2026, 8, 23, 5, 0, 30))      # yesterday's; today's 05:00 was missed
    succeeded(SetMultipliersJob, Time.utc(2026, 8, 24, 11, 1))
    succeeded(EnsureRotationsJob, Time.utc(2026, 8, 23, 22, 31))     # last tick was yesterday 22:30: fine

    expect(described_class.new(now).due).to contain_exactly(VerifyLedgerJob)
  end

  it 'does not count a failed run as a success' do
    JobRun.create!(name: 'refresh_balances', started_at: now - 2.hours, finished_at: now - 2.hours + 1,
                   outcome: 'failed', error: 'boom')
    succeeded(VerifyLedgerJob, now - 1.hour)
    succeeded(SetMultipliersJob, now - 1.minute)
    succeeded(EnsureRotationsJob, now - 1.hour)

    expect(described_class.new(now).due).to contain_exactly(RefreshBalancesJob)
  end

  it 'enqueues exactly the due jobs' do
    succeeded(RefreshBalancesJob, now - 1.hour)
    succeeded(VerifyLedgerJob, now - 1.hour)
    succeeded(SetMultipliersJob, now - 1.hour)

    expect { described_class.call(now: now) }.to have_enqueued_job(EnsureRotationsJob).once
    expect(described_class.call(now: now)).to eq([EnsureRotationsJob])
  end
end

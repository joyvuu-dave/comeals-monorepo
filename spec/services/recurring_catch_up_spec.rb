# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RecurringCatchUp do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before { create(:community) }

  # 2026-08-24 12:00 UTC: refresh_balances (03:00) and verify_ledger (05:00)
  # have ticked today; ensure_rotations (22:30) and send_missed_settlement_mail
  # (16:00) last ticked yesterday.
  let(:now) { Time.utc(2026, 8, 24, 12, 0) }

  def succeeded(job, at)
    JobRun.create!(name: job.run_name, started_at: at - 1.second, finished_at: at, outcome: 'ok')
  end

  it 'is due for every job that has never succeeded' do
    expect(described_class.new(now).due)
      .to contain_exactly(RefreshBalancesJob, VerifyLedgerJob, EnsureRotationsJob, SendMissedSettlementMailJob)
  end

  it 'is not due for a job that succeeded since its last tick, and due for one that missed it' do
    succeeded(RefreshBalancesJob, Time.utc(2026, 8, 24, 3, 0, 30))           # ran at today's tick
    succeeded(VerifyLedgerJob, Time.utc(2026, 8, 23, 5, 0, 30))              # yesterday's; today's 05:00 was missed
    succeeded(EnsureRotationsJob, Time.utc(2026, 8, 23, 22, 31))             # last tick was yesterday 22:30: fine
    succeeded(SendMissedSettlementMailJob, Time.utc(2026, 8, 23, 16, 1))     # last tick was yesterday 16:00: fine

    expect(described_class.new(now).due).to contain_exactly(VerifyLedgerJob)
  end

  it 'leaves out a scheduled class that is not a RecurringJob' do
    allow(Rails.application).to receive(:config_for).with(:recurring).and_return(
      refresh_balances: { class: 'RefreshBalancesJob', schedule: '0 3 * * * UTC' },
      stray: { class: 'ApplicationJob', schedule: '0 4 * * * UTC' }
    )

    expect(described_class.new(now).due).to contain_exactly(RefreshBalancesJob)
  end

  # config/recurring.yml can also hold a command entry, a line of Ruby that
  # Solid Queue runs itself (clear_finished_jobs is one). A mistyped entry
  # could have a blank class or be a plain value. None is a job to catch up.
  it 'leaves out an entry with no job class' do
    allow(Rails.application).to receive(:config_for).with(:recurring).and_return(
      refresh_balances: { class: 'RefreshBalancesJob', schedule: '0 3 * * * UTC' },
      clear_finished_jobs: { command: 'SolidQueue::Job.clear_finished_in_batches', schedule: '12 * * * * UTC' },
      blank_class: { class: '', schedule: '0 4 * * * UTC' },
      not_a_table: 'RefreshBalancesJob'
    )

    expect(described_class.new(now).due).to contain_exactly(RefreshBalancesJob)
  end

  it 'does not count a failed run as a success' do
    JobRun.create!(name: 'refresh_balances', started_at: now - 2.hours, finished_at: now - 2.hours + 1,
                   outcome: 'failed', error: 'boom')
    succeeded(VerifyLedgerJob, now - 1.hour)
    succeeded(EnsureRotationsJob, now - 1.hour)
    succeeded(SendMissedSettlementMailJob, now - 1.hour)

    expect(described_class.new(now).due).to contain_exactly(RefreshBalancesJob)
  end

  # The second matcher counts every job put on the queue, of any class, so
  # a job that is not due fails it too.
  it 'enqueues exactly the due jobs, and returns them' do
    succeeded(RefreshBalancesJob, now - 1.hour)
    succeeded(VerifyLedgerJob, now - 1.hour)
    succeeded(SendMissedSettlementMailJob, now - 1.hour)

    returned = nil
    expect { returned = described_class.call(now: now) }
      .to have_enqueued_job(EnsureRotationsJob).once.and have_enqueued_job.once
    expect(returned).to eq([EnsureRotationsJob])
  end

  # config/puma.rb calls it with no time. At 02:00 today's 03:00 run is
  # not due yet, so the clock has to be read for yesterday's run to count.
  it 'reads the clock when no time is given' do
    succeeded(RefreshBalancesJob, Time.utc(2026, 8, 23, 3, 0, 30))
    succeeded(VerifyLedgerJob, now - 1.hour)
    succeeded(EnsureRotationsJob, now - 1.hour)
    succeeded(SendMissedSettlementMailJob, now - 1.hour)

    travel_to(Time.utc(2026, 8, 24, 2, 0)) do
      expect(described_class.call).to be_empty
    end
    travel_to(Time.utc(2026, 8, 24, 3, 1)) do
      expect(described_class.call).to eq([RefreshBalancesJob])
    end
  end

  # config/puma.rb runs it after boot, outside any rescue, so an error
  # that left it would end the web process. A missed run waits for its
  # next tick instead, and the error goes to Bugsnag.
  describe 'when something fails' do
    before { allow(Rails.error).to receive(:report) }

    it 'queues the other jobs and reports the one that could not be queued' do
      error = StandardError.new('queue refused')
      allow(VerifyLedgerJob).to receive(:perform_later).and_raise(error)

      returned = nil
      expect { returned = described_class.call(now: now) }.not_to raise_error
      expect(returned).to contain_exactly(RefreshBalancesJob, EnsureRotationsJob, SendMissedSettlementMailJob)
      expect(Rails.error).to have_received(:report)
        .with(error, handled: true, severity: :error, context: { job: 'VerifyLedgerJob' })
    end

    # Active Job answers false, with no error, when the adapter refuses a
    # job (ActiveJob::Enqueuing#enqueue).
    it 'does not count a job that perform_later refused, and reports it' do
      allow(VerifyLedgerJob).to receive(:perform_later).and_return(false)

      expect(described_class.call(now: now))
        .to contain_exactly(RefreshBalancesJob, EnsureRotationsJob, SendMissedSettlementMailJob)
      expect(Rails.error).to have_received(:report)
        .with(an_instance_of(RuntimeError).and(having_attributes(message: 'VerifyLedgerJob was not queued')),
              handled: true, severity: :error, context: { job: 'VerifyLedgerJob' })
    end

    # Found by bin/storm with STORM_SOLID_QUEUE=1 STORM_JOBS_PROCESSES=2,
    # 2026-10-20. Two supervisors started at once, each ran the catch-up,
    # and the two enqueues of each job conflicted on the job's
    # limits_concurrency semaphore row. Neither tried again, so neither
    # queued the job, and a job whose tick was missed waits a day for the
    # next one. Every other enqueue in the app tries a conflict again
    # (RetryOnConflict; LiveUpdate.push since 2026-10-09). RetryOnConflict
    # does not retry inside an open transaction, so this example has none.
    context 'when the queue refuses a job once for a conflict' do
      include_context 'with no test transaction'

      it 'tries again and queues it' do
        tries = 0
        allow(VerifyLedgerJob).to receive(:perform_later).and_wrap_original do |original|
          tries += 1
          if tries == 1
            begin
              raise ActiveRecord::SerializationFailure, 'could not serialize access due to concurrent update'
            rescue ActiveRecord::SerializationFailure
              raise SolidQueue::Job::EnqueueError, 'could not serialize access due to concurrent update'
            end
          end
          original.call
        end

        expect(described_class.call(now: now)).to include(VerifyLedgerJob)
        expect(tries).to eq(2)
      end
    end

    it 'queues nothing and reports when the last runs cannot be read' do
      error = ActiveRecord::SerializationFailure.new('could not serialize access')
      allow(JobRun).to receive(:last_success_at).and_raise(error)

      returned = nil
      expect { returned = described_class.call(now: now) }.not_to raise_error
      expect(returned).to eq([])
      expect(Rails.error).to have_received(:report)
        .with(error, handled: true, severity: :error, context: { job: 'all' })
    end
  end
end

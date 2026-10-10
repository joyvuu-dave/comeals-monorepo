# frozen_string_literal: true

require 'rails_helper'

# Each night, every settlement from the last 7 days that still has a cook
# without the cook mail gets another NotifyCooksJob. This covers the
# three ways a cook can miss it: every quick try failed (a mail server
# down for hours), the job was never run (a worker that died), or the
# settlement is not the latest one, which is all the rake task reaches.
RSpec.describe SendMissedCookMailJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let(:ann) { create(:resident, community: community, unit: unit, name: 'Ann') }
  let(:bob) { create(:resident, community: community, unit: unit, name: 'Bob') }

  before { allow(Healthcheck).to receive(:ping) }

  # A settlement made `ago` before now. Each cook in the list cooks one
  # meal, on the days before it: Bob cooks two, so a cook with two bills
  # in one settlement still counts once. One meal a day, so two
  # settlements in one example are more than three days apart.
  def settled(ago, cooks: [ann, bob, bob])
    travel_to(ago.ago) do
      cooks.each_with_index do |cook, days_before|
        meal = create(:meal, community: community, date: community.yesterday - days_before)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
      settle!(cutoff: community.yesterday)
    end
  end

  # A run of another recurring job. Each job's runs are its own: another
  # job's first or last run says nothing about this one.
  def other_job_ran(at:)
    JobRun.create!(name: RefreshBalancesJob.run_name, started_at: at, finished_at: at + 1.second, outcome: 'ok')
  end

  def mailed(reconciliation, *cooks)
    cooks.each do |cook|
      MailDelivery.record!(mailer: NotifyCooksJob::MAILER, about: reconciliation, resident: cook)
    end
  end

  def ran(at:, outcome: 'ok')
    JobRun.create!(name: described_class.run_name, started_at: at, finished_at: at + 1.second, outcome: outcome)
  end

  # The job has been running nightly for a month. Settlements made before
  # its first run are left alone (the last example says why).
  context 'with a month of nightly runs behind it' do
    before { ran(at: 30.days.ago) }

    it 'queues the cook mail again for a settlement from the last 7 days with a cook still not mailed' do
      owed = settled(2.days)
      mailed(owed, ann)
      done = settled(6.days)
      mailed(done, ann, bob)

      expect { described_class.perform_now }.to have_enqueued_job(NotifyCooksJob).with(owed).exactly(:once)

      expect(NotifyCooksJob).not_to have_been_enqueued.with(done)
      run = JobRun.where(name: described_class.run_name).order(:id).last
      expect(run.outcome).to eq('ok')
      expect(run.details).to eq('queued' => [owed.id], 'gave_up' => [])
      expect(Healthcheck).to have_received(:ping).with('send-missed-cook-mail')
    end

    # Another mail about the same settlement, or this mail about another
    # kind of row with the same id, is not this mail about this settlement.
    it 'counts only this mail about this settlement as sent' do
      owed = settled(2.days)
      mailed(owed, ann)
      MailDelivery.record!(mailer: 'new_rotation_email', about: owed, resident: bob)
      MailDelivery.new(mailer: NotifyCooksJob::MAILER, about_type: 'Rotation', about_id: owed.id, resident: bob,
                       sent_at: Time.current).save!(validate: false)

      expect { described_class.perform_now }.to have_enqueued_job(NotifyCooksJob).with(owed).exactly(:once)
    end

    it 'queues nothing for a settlement older than 7 days' do
      old = settled(7.days + 1.hour)

      expect { described_class.perform_now }.not_to have_enqueued_job(NotifyCooksJob)
      expect(old).to be_persisted
    end

    # A cook with no email address cannot be mailed (NotifyCooksJob.recipients),
    # so that cook is never owed the mail, and the job does not try every
    # night for a week.
    it 'does not count a cook with no email address as not mailed' do
      reconciliation = settled(1.day)
      mailed(reconciliation, ann)
      bob.update!(active: false, email: nil)

      expect { described_class.perform_now }.not_to have_enqueued_job(NotifyCooksJob)
    end

    describe 'a settlement that leaves the 7 days with a cook still not mailed' do
      before { allow(Rails.error).to receive(:report).and_call_original }

      def gave_up_reports
        have_received(:report).with(an_instance_of(described_class::GaveUp), anything)
      end

      it 'is reported once, by the first run after it left, with what to run to send it' do
        ran(at: 1.day.ago)
        left = settled(7.days + 1.hour)
        mailed(left, ann)

        described_class.perform_now

        expect(Rails.error).to have_received(:report).with(
          an_instance_of(described_class::GaveUp)
            .and(having_attributes(message: "Reconciliation ##{left.id}: 1 cook still without the cook mail after " \
                                            '7 days, and nothing tries again. To send it: ' \
                                            "NotifyCooksJob.perform_later(Reconciliation.find(#{left.id}))")),
          handled: true, severity: :error, context: { reconciliation_id: left.id, cooks_not_mailed: 1 }
        ).once
        expect(JobRun.where(name: described_class.run_name).order(:id).last.details)
          .to eq('queued' => [], 'gave_up' => [left.id])

        # The next night it is not reported again.
        described_class.perform_now
        expect(Rails.error).to gave_up_reports.once
      end

      # Left the window 3 days ago, after the last good run (5 days ago)
      # and before the failed one (2 days ago). Looking back from the
      # failed run would miss it.
      it 'is reported even when a run failed, because the last good run sets where to look' do
        ran(at: 5.days.ago)
        ran(at: 2.days.ago, outcome: 'failed')
        other_job_ran(at: 1.hour.ago)
        left = settled(10.days)

        described_class.perform_now

        expect(Rails.error).to have_received(:report)
          .with(an_instance_of(described_class::GaveUp), hash_including(context: { reconciliation_id: left.id,
                                                                                   cooks_not_mailed: 2 }))
      end

      # Exactly 7 days old: still in the window, so it is tried once more
      # tonight and reported by the next run, not both tonight.
      it 'is tried, not reported, on the night it is exactly 7 days old' do
        ran(at: 1.day.ago)
        edge = settled(7.days)

        travel_to(edge.created_at + 7.days) do
          expect { described_class.perform_now }.to have_enqueued_job(NotifyCooksJob).with(edge)
        end
        expect(Rails.error).not_to gave_up_reports
      end

      # A run's record keeps the moment it started, and the next run looks
      # back from that moment. So the window this run closes must close at
      # that same moment. Until 2026-10-10 it closed when the work began,
      # after the healthchecks.io ping, and a settlement that left the
      # window in between was reported by both runs.
      it 'is reported by one run only, even when the work starts a moment after the run' do
        ran(at: 2.days.ago)
        start = Time.current.change(usec: 0)
        travel_to(start)
        left = settled(7.days - 1.second)
        # The ping before the work takes two seconds.
        allow(Healthcheck).to receive(:monitor).and_wrap_original do |original, slug, &work|
          travel(2.seconds)
          original.call(slug, &work)
        end

        described_class.perform_now
        travel_to(start + 1.day)
        described_class.perform_now

        expect(Rails.error).to have_received(:report)
          .with(an_instance_of(described_class::GaveUp), hash_including(context: { reconciliation_id: left.id,
                                                                                   cooks_not_mailed: 2 })).once
      end

      it 'is not reported when every cook got the mail' do
        ran(at: 1.day.ago)
        left = settled(7.days + 1.hour)
        mailed(left, ann, bob)

        described_class.perform_now

        expect(Rails.error).not_to gave_up_reports
      end
    end
  end

  # The settlements before the job's first run were made before cook
  # mail was recorded (MailDelivery came with NotifyCooksJob), so they
  # have no rows even when every cook got the mail. Looking at them
  # would mail those cooks a second time on the first night after the
  # deploy, and report them all a week later.
  it 'leaves alone the settlements made before its own first run' do
    other_job_ran(at: 30.days.ago)
    before_the_first_run = settled(1.day)

    expect { described_class.perform_now }.not_to have_enqueued_job(NotifyCooksJob)

    travel_to(8.days.from_now) do
      allow(Rails.error).to receive(:report).and_call_original
      described_class.perform_now
      expect(Rails.error).not_to have_received(:report).with(an_instance_of(described_class::GaveUp), anything)
    end
    expect(before_the_first_run).to be_persisted
  end
end

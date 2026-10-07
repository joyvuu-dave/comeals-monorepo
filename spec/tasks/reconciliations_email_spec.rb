# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'reconciliation email tasks' do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe 'reconciliations:send_cooking_slot_email' do
    include ActiveJob::TestHelper

    after { Rake::Task['reconciliations:send_cooking_slot_email'].reenable }

    def cooked(cook, date)
      meal = create(:meal, community: community, date: date)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
    end

    # The task does not send the mail itself. It queues NotifyCooksJob, the
    # job that mails the cooks after every settlement, so every cook mail
    # goes through that one job. Solid Queue runs one NotifyCooksJob per
    # reconciliation at a time (limits_concurrency), so a run of the task
    # cannot mail a cook while the job is mailing the same cook. When the
    # task sent the mail itself, a run during the job's run mailed a cook
    # twice and then failed on the MailDelivery row the job had written.
    it 'queues NotifyCooksJob for the latest reconciliation and builds no mail itself' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      cooked(cook, Date.yesterday - 3)
      settle!(cutoff: Date.yesterday - 3)
      cooked(cook, Date.yesterday)
      latest = settle!(cutoff: Date.yesterday)
      allow(ReconciliationMailer).to receive(:reconciliation_notify_email)
        .and_return(instance_double(ActionMailer::MessageDelivery, deliver_now: nil))
      allow(Rails.logger).to receive(:info)

      expect { Rake::Task['reconciliations:send_cooking_slot_email'].invoke }
        .to have_enqueued_job(NotifyCooksJob).with(latest).exactly(:once)
      expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
      expect(Rails.logger).to have_received(:info)
        .with("Cooks' Reconciliation Email: queued NotifyCooksJob for reconciliation ##{latest.id}. " \
              'It mails each cook who has not had this mail about it yet.')
    end

    # The examples below run the queued job, to show what a cook gets in
    # the end. spec/jobs/notify_cooks_job_spec.rb has the rest of the job:
    # a failed send, the per-run cap, a second run.
    context 'when the queued job runs' do
      let(:mail_double) { instance_double(ActionMailer::MessageDelivery, deliver_now: nil) }

      before { allow(ReconciliationMailer).to receive(:reconciliation_notify_email).and_return(mail_double) }

      # Two settlements. The newer one has two meals by one cook, who gets
      # one mail; the cook of the older one gets none.
      it 'mails each cook of the latest reconciliation once' do
        old_cook = create(:resident, community: community, unit: unit, multiplier: 2)
        new_cook = create(:resident, community: community, unit: unit, multiplier: 2)
        cooked(old_cook, Date.yesterday - 3)
        settle!(cutoff: Date.yesterday - 3)
        cooked(new_cook, Date.yesterday - 1)
        cooked(new_cook, Date.yesterday)
        latest = settle!(cutoff: Date.yesterday)

        perform_enqueued_jobs { Rake::Task['reconciliations:send_cooking_slot_email'].invoke }

        expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).once
        expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(new_cook, latest)
        expect(mail_double).to have_received(:deliver_now).once
      end

      # The task is for mailing the cooks the job did not reach after the
      # settlement. Bob cooked in both settlements and was mailed about the
      # older one. That record is about a different settlement, so he is
      # still mailed about the newer one. Ann already has the newer one.
      it 'mails only the cooks with no record of this mail about this settlement' do
        ann = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Ann')
        bob = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Bob')
        cooked(bob, Date.yesterday - 3)
        older = settle!(cutoff: Date.yesterday - 3)
        cooked(ann, Date.yesterday - 1)
        cooked(bob, Date.yesterday)
        latest = settle!(cutoff: Date.yesterday)
        MailDelivery.record!(mailer: 'reconciliation_notify_email', about: older, resident: bob)
        MailDelivery.record!(mailer: 'reconciliation_notify_email', about: latest, resident: ann)

        perform_enqueued_jobs { Rake::Task['reconciliations:send_cooking_slot_email'].invoke }

        expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).once
        expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(bob, latest)
      end
    end

    it 'stops with a plain message and a failure status when there is no reconciliation yet' do
      allow(ReconciliationMailer).to receive(:reconciliation_notify_email)

      expect { Rake::Task['reconciliations:send_cooking_slot_email'].invoke }
        .to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output("There is no reconciliation yet, so there are no cooks to mail.\n").to_stderr
      expect(NotifyCooksJob).not_to have_been_enqueued
      expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
    end
  end

  describe 'reconciliations:send_common_house_collection_email' do
    after { Rake::Task['reconciliations:send_common_house_collection_email'].reenable }

    it 'sends the common house collection email' do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      allow(ReconciliationMailer).to receive(:common_house_collection_email).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now)

      Rake::Task['reconciliations:send_common_house_collection_email'].invoke

      expect(ReconciliationMailer).to have_received(:common_house_collection_email).once
      expect(mail_double).to have_received(:deliver_now).once
    end

    it 'handles email delivery failures gracefully' do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      allow(ReconciliationMailer).to receive(:common_house_collection_email).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now).and_raise(Net::SMTPAuthenticationError.new('auth failed'))
      allow(Rails.logger).to receive(:error)

      expect { Rake::Task['reconciliations:send_common_house_collection_email'].invoke }.not_to raise_error
      expect(Rails.logger).to have_received(:error).with(/common_house_collection_email failed/).once
    end
  end
end

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
    after { Rake::Task['reconciliations:send_cooking_slot_email'].reenable }

    def cooked(cook, date)
      meal = create(:meal, community: community, date: date)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
    end

    # Two settlements. The newer one has two meals by one cook, who gets
    # one mail; the cook of the older one gets none.
    it 'sends notification emails to cooks from the latest reconciliation' do
      old_cook = create(:resident, community: community, unit: unit, multiplier: 2)
      new_cook = create(:resident, community: community, unit: unit, multiplier: 2)
      cooked(old_cook, Date.yesterday - 3)
      settle!(cutoff: Date.yesterday - 3)
      cooked(new_cook, Date.yesterday - 1)
      cooked(new_cook, Date.yesterday)
      latest = settle!(cutoff: Date.yesterday)

      mail_double = instance_double(ActionMailer::MessageDelivery)
      allow(ReconciliationMailer).to receive(:reconciliation_notify_email).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now)

      Rake::Task['reconciliations:send_cooking_slot_email'].invoke

      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).once
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(new_cook, latest)
      expect(mail_double).to have_received(:deliver_now).once
    end

    it 'handles email delivery failures gracefully' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community, date: Date.yesterday)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
      settle!(cutoff: Date.yesterday)

      mail_double = instance_double(ActionMailer::MessageDelivery)
      allow(ReconciliationMailer).to receive(:reconciliation_notify_email).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now).and_raise(Net::ReadTimeout)
      allow(Rails.logger).to receive(:error)

      expect { Rake::Task['reconciliations:send_cooking_slot_email'].invoke }.not_to raise_error
      expect(Rails.logger).to have_received(:error).with(/reconciliation_notify_email failed/).once
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

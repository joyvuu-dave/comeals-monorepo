# frozen_string_literal: true

require 'rails_helper'

# The common house mail after a settlement (ADR 0011 rule 9), as a job
# that sends it once and tries a failed send again.
RSpec.describe CommonHouseMailJob do
  include ActiveJob::TestHelper

  let(:community) { create(:community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:unit) { create(:unit, community: community) }
  let(:reconciliation) do
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
    settle!
  end

  # Mail sent by earlier examples stays in this list unless cleared.
  before { ActionMailer::Base.deliveries.clear }

  def rows
    MailDelivery.where(mailer: described_class::MAILER, about: reconciliation)
  end

  # Each send that went out adds the reconciliation to `sent`. While
  # `failing` is true a send raises Net::ReadTimeout, as a mail server
  # that does not answer would.
  def mail_server(sent, failing:)
    allow(ReconciliationMailer).to receive(:common_house_collection_email) do |about|
      mail = instance_double(ActionMailer::MessageDelivery)
      allow(mail).to receive(:deliver_now) do
        raise Net::ReadTimeout if failing.call

        sent << about
      end
      mail
    end
  end

  it 'sends the mail to the common house and records it with no resident, and queues no new try' do
    described_class.perform_now(reconciliation)

    mail = ActionMailer::Base.deliveries.sole
    expect(mail.to).to eq([ReconciliationMailer::COMMON_HOUSE])
    expect(mail.subject).to start_with('Balances to collect')
    expect(rows.pluck(:resident_id)).to eq([nil])
    expect(queue_adapter.enqueued_jobs).to be_empty
  end

  it 'sends nothing when the mail already went out, so a second run sends no second copy' do
    described_class.perform_now(reconciliation)
    described_class.perform_now(reconciliation)

    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(rows.count).to eq(1)
  end

  # The job asks whether this settlement's mail went out, not whether
  # every settlement's did.
  it "sends nothing when this settlement's mail went out, while an earlier settlement still waits for its own" do
    meal = create(:meal, community: community, date: latest - 7)
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('20'))
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
    waiting = settle!(cutoff: latest - 7)
    described_class.perform_now(reconciliation)
    ActionMailer::Base.deliveries.clear

    described_class.perform_now(reconciliation)

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(described_class.not_sent(Reconciliation.all)).to eq([waiting])
  end

  # A row with no resident is one per mailer and record: the partial
  # unique index, not only the model's check.
  it 'has the database refuse a second row for the same mail' do
    described_class.perform_now(reconciliation)

    expect do
      MailDelivery.new(mailer: described_class::MAILER, about: reconciliation, sent_at: Time.current)
                  .save!(validate: false)
    end.to raise_error(ActiveRecord::RecordNotUnique, /index_mail_deliveries_one_to_no_person/)
  end

  # The send went out, and then the row that records it was refused by
  # an error that is not a conflict (a database that went away; a worker
  # that stops between the two is the same case). The mail is promised at
  # least once, not once (ADR 0011 rule 9, #171).
  context 'when the row for a send that went out cannot be written' do
    # The nightly job also sends the cook mail, which is not counted here.
    def house_mail
      ActionMailer::Base.deliveries.select { |mail| mail.to == [ReconciliationMailer::COMMON_HOUSE] }
    end

    before do
      allow(Rails.error).to receive(:report)
      allow(Healthcheck).to receive(:ping)
      # The nightly job has run before, so this settlement is one it looks at.
      JobRun.create!(name: SendMissedSettlementMailJob.run_name, started_at: 30.days.ago, finished_at: 30.days.ago,
                     outcome: 'ok')
      failed_once = false
      allow(MailDelivery).to receive(:record!).and_wrap_original do |original, **attributes|
        unless failed_once
          failed_once = true
          raise ActiveRecord::StatementInvalid, 'PG::ConnectionBad: the database went away'
        end
        original.call(**attributes)
      end
    end

    it 'fails the job, and the nightly job sends a second copy with the same words, then records it' do
      expect { described_class.perform_now(reconciliation) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(rows).to be_empty
      SendMissedSettlementMailJob.perform_now
      perform_enqueued_jobs

      first, second = house_mail
      expect(house_mail.size).to eq(2)
      expect([second.to, second.subject, second.html_part.decoded, second.text_part.decoded])
        .to eq([first.to, first.subject, first.html_part.decoded, first.text_part.decoded])
      expect(rows.count).to eq(1)
    end

    it 'sends no third copy once the second one is recorded' do
      expect { described_class.perform_now(reconciliation) }.to raise_error(ActiveRecord::StatementInvalid)
      described_class.perform_now(reconciliation)
      SendMissedSettlementMailJob.perform_now
      perform_enqueued_jobs

      expect(house_mail.size).to eq(2)
    end
  end

  describe 'the quick tries after a failed send' do
    include ActiveSupport::Testing::TimeHelpers

    before do
      allow(Rails.logger).to receive(:error)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.error).to receive(:report)
    end

    it 'records nothing, tries again 5 minutes, 30 minutes and 2 hours later, then says so in the log' do
      sent = []
      mail_server(sent, failing: -> { true })
      waits = []

      freeze_time do
        described_class.perform_now(reconciliation)
        while (payload = queue_adapter.enqueued_jobs.shift)
          waits << (payload.fetch(:at) - Time.current.to_f)
          ActiveJob::Base.execute(payload)
        end
      end

      expect(waits).to eq([5.minutes, 30.minutes, 2.hours].map(&:to_f))
      expect(ReconciliationMailer).to have_received(:common_house_collection_email).exactly(4).times
      expect(sent).to be_empty
      expect(rows).to be_empty
      # The report names this mail, so the alert says which mail failed.
      expect(Rails.error).to have_received(:report)
        .with(an_instance_of(Net::ReadTimeout), hash_including(context: { mailer: described_class::MAILER }))
        .exactly(4).times
      # The log line names the address, so a person reading the log knows
      # which mail did not go out (MailDeliveryFailure).
      expect(Rails.logger).to have_received(:error)
        .with("common_house_collection_email failed for #{ReconciliationMailer::COMMON_HOUSE}: " \
              'Net::ReadTimeout - Net::ReadTimeout')
        .exactly(4).times
      expect(Rails.logger).to have_received(:warn).with(
        'common_house_collection_email: the common house email was not sent for reconciliation ' \
        "##{reconciliation.id}. Tried 4 times; SendMissedSettlementMailJob tries again each night."
      ).once
    end

    it 'sends the mail on a later try once the mail server answers again' do
      sent = []
      failing = true
      mail_server(sent, failing: -> { failing })

      described_class.perform_now(reconciliation)
      failing = false
      perform_enqueued_jobs

      expect(sent).to eq([reconciliation])
      expect(rows.count).to eq(1)
    end
  end
end

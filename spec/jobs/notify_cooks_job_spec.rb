# frozen_string_literal: true

require 'rails_helper'

# The cook mail after a settlement, as a job that can stop and start again
# without mailing anyone twice (#71).
RSpec.describe NotifyCooksJob do
  include ActiveJob::TestHelper

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:cooks) do
    %w[Ann Bob Cid].map { |name| create(:resident, community: community, unit: unit, multiplier: 2, name: name) }
  end
  let(:reconciliation) do
    cooks.each_with_index do |cook, i|
      meal = create(:meal, community: community, date: Date.yesterday - i)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
    settle!
  end

  before { allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) } # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain

  it 'mails every cook once and records each send' do
    described_class.perform_now(reconciliation)

    cooks.each do |cook|
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
    end
    expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to match_array(cooks.map(&:id))
  end

  it 'skips the cooks already mailed, so a second run sends nothing twice' do
    MailDelivery.record!(mailer: 'reconciliation_notify_email', about: reconciliation, resident: cooks[0])

    described_class.perform_now(reconciliation)
    described_class.perform_now(reconciliation)

    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email).with(cooks[0], reconciliation)
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cooks[1], reconciliation).once
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cooks[2], reconciliation).once
  end

  # Each cook in `mailed` once per send that went out. A send to a cook
  # in `failing` raises Net::ReadTimeout, as a mail server that does not
  # answer would.
  def mail_fails_for(failing, mailed)
    allow(ReconciliationMailer).to receive(:reconciliation_notify_email) do |cook, _|
      mail = instance_double(ActionMailer::MessageDelivery)
      allow(mail).to receive(:deliver_now) do
        raise Net::ReadTimeout if failing.include?(cook)

        mailed << cook
      end
      mail
    end
  end

  it 'does not record a send that failed, so the next run tries that cook again' do
    mailed = []
    failing = [cooks[1]]
    mail_fails_for(failing, mailed)
    allow(Rails.logger).to receive(:error)
    allow(Rails.error).to receive(:report)

    described_class.perform_now(reconciliation)

    expect(mailed).to contain_exactly(cooks[0], cooks[2])
    # The report names this mail, so the alert says which mail failed.
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(Net::ReadTimeout), hash_including(context: { mailer: 'reconciliation_notify_email' })).once
    expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to contain_exactly(cooks[0].id, cooks[2].id)

    # The mail server works again. The next run mails only the cook whose
    # send failed.
    failing.clear
    described_class.perform_now(reconciliation)

    expect(mailed.drop(2)).to eq([cooks[1]])
    expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to match_array(cooks.map(&:id))
  end

  # A send that failed is tried again soon, by the job itself: a mail
  # server that is down for a few minutes should not cost a cook the mail
  # until the nightly SendMissedCookMailJob runs. After the last quick try
  # the job ends without an error, and the nightly job takes over.
  describe 'the quick tries after a failed send' do
    include ActiveSupport::Testing::TimeHelpers

    it 'tries again 5 minutes, 30 minutes and 2 hours later, then stops and says so in the log' do
      mailed = []
      mail_fails_for([cooks[1]], mailed)
      allow(Rails.logger).to receive(:error)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.error).to receive(:report)
      waits = []

      freeze_time do
        described_class.perform_now(reconciliation)
        while (payload = queue_adapter.enqueued_jobs.shift)
          waits << (payload.fetch(:at) - Time.current.to_f)
          ActiveJob::Base.execute(payload)
        end
      end

      expect(waits).to eq([5.minutes, 30.minutes, 2.hours].map(&:to_f))
      expect(mailed).to contain_exactly(cooks[0], cooks[2])
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cooks[1], reconciliation)
                                                                                 .exactly(4).times
      expect(Rails.logger).to have_received(:warn).with(
        "reconciliation_notify_email: 1 cook email not sent for reconciliation ##{reconciliation.id}. " \
        'Tried 4 times; SendMissedCookMailJob tries again each night.'
      ).once
    end

    it 'mails the cook on a later try once the mail server answers again' do
      mailed = []
      failing = [cooks[1]]
      mail_fails_for(failing, mailed)
      allow(Rails.logger).to receive(:error)
      allow(Rails.error).to receive(:report)

      described_class.perform_now(reconciliation)
      failing.clear
      perform_enqueued_jobs

      expect(mailed).to match_array(cooks)
      expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to match_array(cooks.map(&:id))
      expect(queue_adapter.enqueued_jobs).to be_empty
    end
  end

  # The row for a send that went out can be refused for a conflict like
  # any other write (ADR 0005). Before 2026-10-10 nothing tried it again:
  # the refusal ended the run, so the cook had the mail but no row, and
  # the cooks after them had neither. SendMissedCookMailJob then queued
  # the job again for the missing rows, and the first cook got the mail a
  # second time. The row is now tried again like any other refused write.
  # No test transaction, because a retry can only happen outside one
  # (RetryOnConflict).
  context 'when the row for a send that went out is refused once' do
    include_context 'with no test transaction'

    it 'records the send on the next try, and mails each cook once, even after the nightly job' do
      mailed = []
      mail_fails_for([], mailed)
      allow(Rails.error).to receive(:report)
      allow(Healthcheck).to receive(:ping)
      # The nightly job has run before, so this settlement is one it looks at.
      JobRun.create!(name: SendMissedCookMailJob.run_name, started_at: 30.days.ago, finished_at: 30.days.ago,
                     outcome: 'ok')
      refused = false
      allow(MailDelivery).to receive(:create!).and_wrap_original do |original, **attributes|
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access'
        end
        original.call(**attributes)
      end

      described_class.perform_now(reconciliation)
      SendMissedCookMailJob.perform_now
      perform_enqueued_jobs

      expect(mailed).to match_array(cooks)
      expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to match_array(cooks.map(&:id))
    end
  end

  it 'asks for another run when the per-run cap cut the list short' do
    stub_const('PacedDelivery::CAP', 2)
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now(reconciliation) }.to have_enqueued_job(described_class).with(reconciliation)
    expect(MailDelivery.where(about: reconciliation).count).to eq(2)

    perform_enqueued_jobs
    expect(MailDelivery.where(about: reconciliation).count).to eq(3)
  end

  # SettleAndNotify queues this job inside the settlement's transaction,
  # so the job row commits or rolls back with the settlement. Held back
  # until the commit, it would be a write after the commit again.
  it 'is queued at once, inside the transaction that queues it' do
    expect(described_class.enqueue_after_transaction_commit).to be(false)
  end

  # SettleAndNotify and the reconciliations:send_cooking_slot_email task
  # both queue this job. Solid Queue runs one job per key at a time and
  # holds the next one back until the first ends, so the two cannot mail
  # the same cook at the same moment. The test queue adapter does not
  # apply the limit, so this example pins the settings instead.
  it 'runs one job per reconciliation at a time, and holds the next one back until it ends' do
    expect(described_class.new(reconciliation).concurrency_key).to eq("NotifyCooksJob/#{reconciliation.id}")
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_on_conflict).to eq(:block)
  end

  # A retired resident, a child, or someone who cannot cook may have no
  # email address (Resident#email_presence), and a retired cook can still
  # have a bill in a settlement. The mail is not stubbed here: the test
  # delivery method checks the address the same way SMTP does, and an
  # empty one raises ArgumentError, which PacedDelivery does not catch.
  # Before the fix the job stopped at that cook, every cook after it got
  # nothing, and every new run stopped at the same cook.
  context 'when a cook has no email address' do
    # Bob cooks twice: one line in the log for him, not two.
    let(:reconciliation) do
      [cooks[0], cooks[1], cooks[1], cooks[2]].each_with_index do |cook, i|
        meal = create(:meal, community: community, date: Date.yesterday - i)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
      settle!
    end

    before { allow(ReconciliationMailer).to receive(:reconciliation_notify_email).and_call_original }

    it 'mails every other cook, records nothing for that one, and says so in the log once' do
      reconciliation
      cooks[1].update!(active: false, email: nil)
      logged = []
      allow(Rails.logger).to receive(:info).and_wrap_original do |original, line|
        logged << line
        original.call(line)
      end

      expect { described_class.perform_now(reconciliation) }.not_to raise_error

      expect(ActionMailer::Base.deliveries.flat_map(&:to))
        .to contain_exactly(cooks[0].email, cooks[2].email)
      expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to contain_exactly(cooks[0].id, cooks[2].id)
      line = "reconciliation_notify_email: not sent to resident ##{cooks[1].id}, who has no email address " \
             "(reconciliation ##{reconciliation.id})"
      expect(logged.grep(/not sent to/)).to eq([line])
    end
  end

  it 'has nothing to do for a reconciliation whose cooks were all mailed' do
    cooks.each do |cook|
      MailDelivery.record!(mailer: 'reconciliation_notify_email', about: reconciliation, resident: cook)
    end

    expect { described_class.perform_now(reconciliation) }.not_to have_enqueued_job
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end
end

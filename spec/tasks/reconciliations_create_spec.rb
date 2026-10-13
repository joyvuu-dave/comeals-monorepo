# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'reconciliations:create' do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  # The cook mail is a job (NotifyCooksJob). Run it inline so these examples
  # see the whole of what a settlement does.
  around { |example| perform_enqueued_jobs { example.run } }

  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule
  # 2). The dates below count back from it.
  let(:latest) { Reconciliation.latest_cutoff(community.today) }

  after do
    Rake::Task['reconciliations:create'].reenable
    Rake::Task['billing:recalculate'].reenable
  end

  before do
    allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain
  end

  it 'creates a reconciliation and assigns unreconciled meals with bills' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: community.today - 14)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    create(:meal_resident, meal: meal, resident: eater, community: community)

    expect { Rake::Task['reconciliations:create'].invoke }
      .to change(Reconciliation, :count).by(1)

    reconciliation = Reconciliation.last
    expect(reconciliation.community).to eq(community)
    expect(meal.reload.reconciliation).to eq(reconciliation)
  end

  # ADR 0011 rule 2: the cutoff is 14 days back, so a cook has time to
  # fix a cost. A meal from 13 days back waits for the next settlement.
  it 'settles with a cutoff 14 days back, and leaves a newer meal open' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    old, newer = [14, 13].map do |days|
      create(:meal, community: community, date: community.today - days).tap do |meal|
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
        create(:meal_resident, meal: meal, resident: cook, community: community)
      end
    end

    Rake::Task['reconciliations:create'].invoke

    expect(Reconciliation.last.end_date).to eq(community.today - 14)
    expect([old.reload.reconciliation, newer.reload.reconciliation]).to eq([Reconciliation.last, nil])
  end

  # ADR 0011 rule 3: a blank cost means the cook has not said what they
  # spent. The task settles the rest and leaves that meal open.
  it 'leaves a meal with a blank cost open, and settles the others' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    helper = create(:resident, community: community, unit: unit, multiplier: 2)
    paid, waiting = [20, 15].map do |days|
      create(:meal, community: community, date: community.today - days).tap do |meal|
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
        create(:meal_resident, meal: meal, resident: cook, community: community)
      end
    end
    create(:bill, meal: waiting, resident: helper, community: community, amount: 0)

    Rake::Task['reconciliations:create'].invoke

    expect([paid.reload.reconciliation, waiting.reload.reconciliation]).to eq([Reconciliation.last, nil])
  end

  # The task runs in the app's zone, Los Angeles. At 05:30 UTC on
  # 2026-04-10 it is April 10 in New York and still April 9 in Los
  # Angeles. A New York community's latest cutoff is March 27, 14 days
  # before its April 10. The app zone's would be March 26, and the meal
  # of March 27 would wait one more day.
  it "counts the 14 days from the community's today, not the app zone's" do
    travel_to(Time.utc(2026, 4, 10, 5, 30)) do
      new_york = create(:community, timezone: 'America/New_York')
      new_york_unit = create(:unit, community: new_york)
      cook = create(:resident, community: new_york, unit: new_york_unit, multiplier: 2)
      eater = create(:resident, community: new_york, unit: new_york_unit, multiplier: 2)
      meal = create(:meal, community: new_york, date: Date.new(2026, 3, 27))
      create(:bill, meal: meal, resident: cook, community: new_york, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: eater, community: new_york)
      expect(Date.current - 14).to eq(Date.new(2026, 3, 26))

      Rake::Task['reconciliations:create'].invoke

      expect(Reconciliation.pluck(:end_date)).to eq([Date.new(2026, 3, 27)])
      expect(meal.reload.reconciliation).to eq(Reconciliation.last)
    end
  end

  it 'persists settlement balances' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    create(:meal_resident, meal: meal, resident: eater, community: community)

    Rake::Task['reconciliations:create'].invoke

    reconciliation = Reconciliation.last
    expect(reconciliation.reconciliation_balances.count).to be > 0
  end

  it 'sends notification emails to cooks' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
    create(:meal_resident, meal: meal, resident: cook, community: community)

    Rake::Task['reconciliations:create'].invoke

    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email)
      .with(cook, instance_of(Reconciliation))
  end

  it 'does not sweep a meal scheduled for today — its receipt and attendance are not final' do
    # Failure scenario from issue #3: cooks sign up days ahead, creating $0 bill
    # rows. Running the task on the morning of a meal day must not settle
    # tonight's meal at $0.
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    tonight = create(:meal, community: community, date: community.today)
    create(:bill, meal: tonight, resident: cook, community: community, amount: BigDecimal('0'))
    create(:meal_resident, meal: tonight, resident: eater, community: community)

    expect { Rake::Task['reconciliations:create'].invoke }
      .not_to change(Reconciliation, :count)

    expect(tonight.reload.reconciliation_id).to be_nil
  end

  # Two settlements at the same moment — this task and a reconciler's
  # click in the app — and this one lost: the other claimed the meals
  # first (Settlement::Contested). The period is settled, by the other
  # side, so this is a skip like an empty period, not a crash. It used to
  # exit 1 and page healthchecks.io about a settlement that went fine.
  it 'exits clean when another settlement claimed the meals first' do
    community
    allow(SettleAndNotify).to receive(:call).and_raise(Settlement::Contested, 'assign_meals: 0 of 3 claimed')
    allow(Rails.logger).to receive(:info)

    expect { Rake::Task['reconciliations:create'].invoke }.not_to raise_error

    expect(Rails.logger).to have_received(:info).with(/another settlement claimed the meals first/)
  end

  it 'skips communities with no unreconciled meals with bills' do
    # Community with no meals at all
    create(:resident, community: community, unit: unit)

    expect { Rake::Task['reconciliations:create'].invoke }
      .not_to change(Reconciliation, :count)
  end

  it 'skips meals that have no bills' do
    create(:meal, community: community, date: latest)

    expect { Rake::Task['reconciliations:create'].invoke }
      .not_to change(Reconciliation, :count)
  end

  it 'recalculates resident balances after reconciliation' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    create(:meal_resident, meal: meal, resident: eater, community: community)

    Rake::Task['reconciliations:create'].invoke

    # After reconciliation, unreconciled balances should be zero
    # (the meal is now reconciled, so the running balance is 0)
    cook_balance = ResidentBalance.find_by(resident: cook)
    eater_balance = ResidentBalance.find_by(resident: eater)
    expect(cook_balance.amount).to eq(BigDecimal('0'))
    expect(eater_balance.amount).to eq(BigDecimal('0'))
  end

  it 'mails each cook once, however many meals they cooked' do
    twice = create(:resident, community: community, unit: unit, multiplier: 2)
    once = create(:resident, community: community, unit: unit, multiplier: 2)
    [3, 2].each do |days_ago|
      meal = create(:meal, community: community, date: latest - days_ago)
      create(:bill, meal: meal, resident: twice, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: meal, resident: twice, community: community)
    end
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: once, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: meal, resident: once, community: community)

    Rake::Task['reconciliations:create'].invoke

    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).twice
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(twice, Reconciliation.last).once
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(once, Reconciliation.last).once
  end

  it 'still mails the second cook when the first mail fails' do
    first = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Aaron First')
    second = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Zoe Second')
    [first, second].each_with_index do |cook, i|
      meal = create(:meal, community: community, date: latest - i)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
    end

    delivered = []
    allow(ReconciliationMailer).to receive(:reconciliation_notify_email) do |cook, _reconciliation|
      mail = instance_double(ActionMailer::MessageDelivery)
      allow(mail).to receive(:deliver_now) do
        raise Net::ReadTimeout if cook == first

        delivered << cook
      end
      mail
    end
    allow(Rails.logger).to receive(:error)

    expect { Rake::Task['reconciliations:create'].invoke }.not_to raise_error

    expect(delivered).to eq([second])
    # The first try and each quick try after it (NotifyCooksJob::RETRY_WAITS),
    # which the test adapter runs at once instead of minutes later.
    expect(Rails.logger).to have_received(:error).with(/reconciliation_notify_email failed/)
                                                 .exactly(NotifyCooksJob::RETRY_WAITS.size + 1).times
  end
end

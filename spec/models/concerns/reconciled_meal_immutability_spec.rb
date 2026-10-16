# frozen_string_literal: true

require 'rails_helper'

# ReconciledMealImmutability reads the meals table, never the row's loaded
# `meal`. Every admin write loads the association first: Bill's
# block_if_reconciled calls resource.reconciled?, which delegates to meal.
# A settlement can claim the meal between that read and the save. Until
# 2026-09-24 the guard read the cached meal, let the write through, and
# the database trigger refused it with an exception (a crash page in
# admin) instead of the guard's sentence.
#
# Lock hunt, 2026-09-21; the first example was red when written.
RSpec.describe ReconciledMealImmutability do
  let(:community) { create(:community) }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule
  # 2). The dates below count back from it.
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: latest) }

  def settle
    Settlement.run!(cutoff: latest)
    expect(meal.reload).to be_reconciled
  end

  it 'reads the meal row, so it refuses a bill edit after a settlement claimed the loaded meal' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: cook, community: community)

    # What the admin controller does before the write: load the row and ask
    # it whether its meal is reconciled. This loads bill.meal.
    stale = Bill.find(bill.id)
    expect(stale.reconciled?).to be(false)

    settle

    expect { stale.update(amount: BigDecimal('5')) }.not_to raise_error
    expect(stale.errors[:base]).to include('Meal has been reconciled.')
    expect(bill.reload.amount).to eq(BigDecimal('10'))
  end

  it 'leaves a row with no meal to the presence validation' do
    bill = Bill.new(meal: nil, resident: cook, amount: BigDecimal('10'))

    expect { bill.valid? }.not_to raise_error
    expect(bill.errors[:base]).to be_empty
    expect(bill.errors[:meal]).to include('must exist')
  end

  it 'says reconciled first when the meal is also closed, on a create' do
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    settle
    meal.update_columns(closed: true, closed_at: 1.hour.ago)

    guest = Guest.new(meal: Meal.find(meal.id), resident: cook)

    expect(guest.valid?).to be(false)
    expect(guest.errors[:base].first).to eq('Meal has been reconciled.')
  end

  # The statements that ask whether a meal is settled, with the meal id
  # each one asks about. Each is one read of the meals table with the
  # comeals.correcting setting.
  def settled_checks_during(&)
    checks = []
    subscriber = lambda { |*, payload|
      next unless payload[:sql].include?("current_setting('comeals.correcting'")

      checks << payload[:type_casted_binds].first
    }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    checks
  end

  # Every save of a bill, a sign-up or a guest runs the check twice: once
  # in the validation and once in the before_save. A row that stays on its
  # meal has one meal to check, so asking about "the meal it was on" again
  # would read the same row a second time for the same answer.
  it 'reads the meal once per check when the row stays on it, and both meals when the row moves' do
    other = create(:meal, community: community, date: latest - 7)
    eater = create(:resident, community: community, unit: unit)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    attendance = create(:meal_resident, meal: other, resident: eater, community: community)

    expect(settled_checks_during { bill.update!(amount: BigDecimal('12')) }).to eq([meal.id, meal.id])
    expect(settled_checks_during { attendance.update!(meal: meal) }).to eq([meal.id, other.id, meal.id, other.id])
  end

  it 'refuses a save that skips validation, with the sentence and not the trigger' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    settle

    fresh = Bill.find(bill.id)
    fresh.amount = BigDecimal('5')

    expect { fresh.save(validate: false) }.not_to raise_error
    expect(fresh.save(validate: false)).to be(false)
    expect(fresh.errors[:base]).to eq(['Meal has been reconciled.'])
    expect(bill.reload.amount).to eq(BigDecimal('10'))
  end
end

# frozen_string_literal: true

require 'rails_helper'

# LocksItsMealFirst says (app/models/concerns/locks_its_meal_first.rb,
# "Prepended, so it runs before every other guard: ReconciledMealImmutability
# then reads the meal under this lock instead of from a stale snapshot").
#
# That holds only when the row's `meal` association is not loaded yet.
# Every admin write loads it first: Bill's block_if_reconciled calls
# resource.reconciled?, which delegates to meal. The guard then reads the
# cached object, not the row under the lock. The database trigger still
# refuses the write, so no money moves; but it is refused with an
# exception, not with the guard's sentence.
#
# This spec pins which one happens. It is green if the comment is true
# (the guard refuses, the record has the error) and red if the trigger
# refuses first (ActiveRecord::StatementInvalid).
#
# Lock hunt, 2026-09-21.
RSpec.describe ReconciledMealImmutability do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }

  it 'reads the meal fresh under the LocksItsMealFirst lock, so it refuses a bill edit after a settlement' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: cook, community: community)

    # What the admin controller does before the write: load the row and ask
    # it whether its meal is reconciled. This loads bill.meal.
    stale = Bill.find(bill.id)
    expect(stale.reconciled?).to be(false)

    Settlement.run!(cutoff: Date.yesterday)
    expect(meal.reload).to be_reconciled

    # The guard's answer, if it reads the meal under the lock.
    expect { stale.update(amount: BigDecimal('5')) }.not_to raise_error
    expect(stale.errors[:base]).to include('Meal has been reconciled.')
  end
end

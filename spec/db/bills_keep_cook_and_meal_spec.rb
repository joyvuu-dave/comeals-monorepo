# frozen_string_literal: true

require 'rails_helper'

# A bill is "this cook on this meal" (ADR 0009, #135). The Bill model
# refuses a new cook or a new meal on a saved bill (spec/models/bill_spec.rb,
# "a saved bill keeps its cook and its meal"); this trigger makes
# PostgreSQL refuse it from every write that skips the model
# (update_columns, update_all, a rake task, psql), with the same words.
RSpec.describe 'bills_same_cook_and_meal trigger' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let!(:bill) { create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50')) }

  def refusal
    a_string_including(Bill::COOK_AND_MEAL_FIXED)
  end

  it 'refuses a new cook that skips the model, as a check violation in the words the model uses' do
    other_cook = create(:resident, community: community, unit: unit)

    expect { bill.update_columns(resident_id: other_cook.id) }.to raise_error(ActiveRecord::CheckViolation, refusal)
  end

  it 'refuses a new meal that skips the model, when both meals are open' do
    other_meal = create(:meal, community: community, date: meal.date + 1)

    expect { Bill.where(id: bill.id).update_all(meal_id: other_meal.id) }
      .to raise_error(ActiveRecord::CheckViolation, refusal)
  end

  # Each write runs in its own savepoint: a refused statement ends the
  # transaction it runs in, and the example's transaction must go on.
  it 'lets every other column change' do
    Bill.transaction(requires_new: true) do
      Bill.where(id: bill.id).update_all(amount: 0, no_cost: true, resident_id: cook.id, meal_id: meal.id)
    end

    expect(bill.reload).to have_attributes(amount: 0, no_cost: true)
  end
end

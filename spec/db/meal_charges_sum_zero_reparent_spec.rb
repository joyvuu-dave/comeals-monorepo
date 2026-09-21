# frozen_string_literal: true

require 'rails_helper'

# ADR 0008: the deferred trigger meal_charges_sum_zero refuses a commit that
# leaves a meal's lines unbalanced, and the repair bypass does not turn it
# off. The existing trigger spec covers an insert, a delete and an amount
# change. This one covers the write the trigger has a special branch for: an
# UPDATE that moves a line from one settled meal to another. Both meals must
# still balance afterwards, so both ids are checked (migration
# 20260917130000, "An UPDATE that moves a line between meals must leave both
# of them balanced").
#
# Invariant hunt, 2026-09-21. Green when written: a pin, not a finding.
RSpec.describe 'meal charges sum-zero trigger on a re-parented line' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }
  # Different people on the second meal, so that a moved line meets no
  # unique index (one credit per cook, one debit per attendee, per meal)
  # and only the sum-zero trigger can refuse it.
  let(:other_cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Other cook') }
  let(:other_eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Other eater') }

  # Two settled meals in one settlement, each balanced on its own: the cook
  # is credited what was spent and the two eaters are charged half each.
  let!(:first_meal) { settled_meal(BigDecimal('80'), Date.yesterday - 1, cook, eater) }
  let!(:second_meal) { settled_meal(BigDecimal('40'), Date.yesterday, other_cook, other_eater) }

  before { settle!(cutoff: Date.yesterday) }

  def settled_meal(amount, date, cook, eater)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: amount)
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    meal
  end

  def repair
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      yield
    end
  end

  def sum_for(meal)
    MealCharge.where(meal_id: meal.id).sum(:amount)
  end

  it 'starts from two balanced meals' do
    expect([sum_for(first_meal), sum_for(second_meal)]).to eq([BigDecimal('0'), BigDecimal('0')])
  end

  it 'refuses a repair that moves one line to another meal, because the meal it left is now unbalanced' do
    credit = MealCharge.find_by!(meal_id: first_meal.id, kind: 'credit')

    expect { repair { MealCharge.where(id: credit.id).update_all(meal_id: second_meal.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /meal #{first_meal.id} refused: its stored lines sum to -80/)

    expect(credit.reload.meal_id).to eq(first_meal.id)
  end

  it 'refuses a move of several lines, judging both meals' do
    # Move both debits together: the meal they left keeps only its credit
    # (+80), and the meal they went to is long by the same (-80). Whichever
    # id the trigger visits first, the commit is refused.
    lines = MealCharge.where(meal_id: first_meal.id, kind: 'debit')

    expect { repair { lines.update_all(meal_id: second_meal.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /refused: its stored lines sum to/)

    expect([sum_for(first_meal), sum_for(second_meal)]).to eq([BigDecimal('0'), BigDecimal('0')])
  end

  it 'lets a repair move every line of a meal together, since both meals still balance' do
    repair { MealCharge.where(meal_id: first_meal.id).update_all(meal_id: second_meal.id) }

    expect(sum_for(first_meal)).to eq(BigDecimal('0'))
    expect(sum_for(second_meal)).to eq(BigDecimal('0'))
    expect(MealCharge.where(meal_id: second_meal.id).count).to eq(6)
  end
end

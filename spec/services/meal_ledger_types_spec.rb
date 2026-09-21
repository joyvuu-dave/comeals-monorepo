# frozen_string_literal: true

require 'rails_helper'

# The sigs on MealLedger are checked when the code runs, in this suite and
# in production (docs/sorbet.md, "Runtime behaviour"). This pins that the
# checks are on: a wrong value at the ledger's edge raises before any
# arithmetic happens. Runtime type checks only, in their own file, because
# mutant reinserts a method without its sig and so the unmutated code fails
# these (spec/support/mutant/specs.rb, MUTANT_SIG_CHECK_SPECS).
RSpec.describe MealLedger do
  it 'refuses a line with a nil amount' do
    expect do
      MealLedger::Line.new(meal_id: 1, resident_id: 1, kind: :credit, amount: nil,
                           multiplier: nil, unit_cost: BigDecimal('0'), bill_amount: nil)
    end.to raise_error(TypeError, /amount/)
  end

  it 'refuses a float where money must be BigDecimal' do
    expect do
      MealLedger::Summary.new(total_cost: 1.5, effective_cost: BigDecimal('0'),
                              unit_cost: BigDecimal('0'), subsidized: false)
    end.to raise_error(TypeError, /total_cost/)
  end

  it 'refuses a relation, which would let a query run inside the ledger' do
    expect { described_class.new(Meal.all) }.to raise_error(TypeError, /meals/)
  end
end

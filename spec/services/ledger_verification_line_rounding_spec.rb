# frozen_string_literal: true

require 'rails_helper'

# Every stored line is rounded to 8 places on the way into meal_charges
# (ActiveModel rounds a decimal to the column's scale), and nothing puts the
# rounded-off part anywhere. So a meal's stored lines do not sum to zero;
# they sum to whatever the rounding dropped. Equal unit costs drop the same
# amount in the same direction every time, so a reconciliation of many
# similar meals adds those drops up. The line-item check compares the sum
# against a fixed epsilon that does not grow with the number of lines, so a
# large enough correct ledger fails the check.
RSpec.describe LedgerVerification do
  describe 'stored line rounding' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 1, name: 'Cook') }
    let(:eaters) do
      %w[Ann Bo Cy].map { |name| create(:resident, community: community, unit: unit, multiplier: 1, name: name) }
    end

    # $1.00 split three ways is 0.333333333..., stored as 0.33333333 three
    # times. Each meal's stored lines sum to 0.00000001, always in the same
    # direction.
    def cook_a_dollar_meal
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
      meal
    end

    it 'reports a correct ledger as broken once enough meals share a repeating unit cost' do
      meals = Array.new(101) { cook_a_dollar_meal }
      reconciliation = settle!(cutoff: Date.yesterday)

      # The settlement itself is right: in memory the lines balance, and every
      # stored balance is within a cent of its lines. Only the stored lines
      # carry the rounding.
      per_meal = MealCharge.where(meal_id: meals.map(&:id)).group(:meal_id).sum(:amount)
      expect(per_meal.values.uniq).to eq([BigDecimal('0.00000001')])
      expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(0)

      run = described_class.call

      expect(run).to be_passed
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Issue #85. Every stored line used to be divided at about twenty digits
# and rounded to 8 places on the way into meal_charges (ActiveModel rounds
# a decimal to the column's scale), and nothing put the rounded-off part
# anywhere. So a meal's stored lines summed to whatever the rounding
# dropped, always in the same direction for equal unit costs, and the
# line-item check compared the total against a fixed 0.000001 that did not
# grow with the number of lines. 101 one-dollar meals with three eaters
# each failed the check on a ledger that was right.
#
# Now every share is allocated at the ledger grain (MODELS.md, "The ledger
# grain"), so each meal's stored lines sum to exactly zero, and the check
# demands exactly zero.
RSpec.describe LedgerVerification do
  describe 'stored line rounding' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 1, name: 'Cook') }
    let(:eaters) do
      %w[Ann Bo Cy].map { |name| create(:resident, community: community, unit: unit, multiplier: 1, name: name) }
    end

    # $1.00 split three ways: 0.33333334 to the lowest resident id and
    # 0.33333333 to the other two, so the three debits and the credit sum
    # to exactly zero.
    def cook_a_dollar_meal
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
      meal
    end

    it 'passes a large correct ledger whose meals all share a repeating unit cost' do
      meals = Array.new(101) { cook_a_dollar_meal }
      reconciliation = settle!(cutoff: Date.yesterday)

      per_meal = MealCharge.where(meal_id: meals.map(&:id)).group(:meal_id).sum(:amount)
      expect(per_meal.size).to eq(101)
      expect(per_meal.values.uniq).to eq([BigDecimal('0')])
      expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(0)

      run = described_class.call

      expect(run).to be_passed
    end

    it 'reports stored lines that sum to one unit of the grain, not only to more than the old epsilon' do
      cook_a_dollar_meal
      reconciliation = settle!(cutoff: Date.yesterday)
      line = MealCharge.for_reconciliation(reconciliation).where(kind: 'debit').order(:resident_id).first

      # Settled data is immutable by design, so this goes behind the guards
      # on purpose, as a person with psql access can. The deferred trigger
      # that refuses an unbalanced meal at commit never fires here, because
      # the test transaction never commits; that trigger has its own spec.
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        MealCharge.where(id: line.id).update_all(amount: line.amount - BigDecimal('0.00000001'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      detail = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'line_items' }
      expect(detail['differences']).to include('resident_id' => nil, 'stored' => nil, 'source' => '-0.00000001')
    end
  end
end

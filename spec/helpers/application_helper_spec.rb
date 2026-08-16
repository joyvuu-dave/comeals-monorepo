# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#price_category_label' do
    it 'returns "Child" for multiplier 1' do
      expect(helper.price_category_label(1)).to eq('Child')
    end

    it 'returns "Adult" for multiplier 2' do
      expect(helper.price_category_label(2)).to eq('Adult')
    end

    it 'returns fractional adult for other multipliers' do
      expect(helper.price_category_label(3)).to eq('Adult x 1.5')
    end
  end

  describe '#child_pricing_rule_sentence' do
    def sentence(free_below, full_at)
      helper.child_pricing_rule_sentence(
        Community.new(free_below_age: free_below, full_price_age: full_at)
      )
    end

    it 'spells out the three bands from the configured ages' do
      expect(sentence(5, 12)).to eq(
        'Children under 5 eat free, children 5 to 11 pay half price, ' \
        'and everyone 12 and older pays full price.'
      )
    end

    it 'reads the ages from the community, not from fixed numbers' do
      expect(sentence(3, 10)).to eq(
        'Children under 3 eat free, children 3 to 9 pay half price, ' \
        'and everyone 10 and older pays full price.'
      )
    end

    it 'drops the half-price band when the ages are equal' do
      expect(sentence(7, 7)).to eq(
        'Children under 7 eat free, and everyone 7 and older pays full price.'
      )
    end

    it 'drops the free band when free-below is 0' do
      expect(sentence(0, 12)).to eq(
        'Children under 12 pay half price, and everyone 12 and older pays full price.'
      )
    end

    it 'says everyone pays full price when both ages are 0' do
      expect(sentence(0, 0)).to eq('Everyone pays full price.')
    end
  end

  # Pins the deliberate display policy: a blank cell means "no amount
  # to show", never "$0.00". See the helper's comment.
  describe '#meal_cost_cell' do
    let(:resident) { create(:resident, community: community, unit: unit) }

    it 'formats the cost as currency' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      expect(helper.meal_cost_cell(meal, :total_cost)).to eq('$50.00')
    end

    it 'is blank when the value is zero' do
      meal = create(:meal, community: community)

      expect(helper.meal_cost_cell(meal, :total_cost)).to be_nil
    end

    it 'is blank when the meal was settled before line items existed' do
      # A reconciled meal with attendance but no meal_charges is the
      # unrecorded case: MealCostSummary.for returns nil on purpose.
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update_columns(reconciliation_id: reconciliation.id)
      meal.reload

      expect(helper.meal_cost_cell(meal, :total_cost)).to be_nil
    end
  end
end

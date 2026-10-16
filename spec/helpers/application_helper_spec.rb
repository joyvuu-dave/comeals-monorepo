# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#price_category_label' do
    it 'returns "Child" for a child at half price' do
      expect(helper.price_category_label(Multiplier::HALF)).to eq('Child')
    end

    it 'returns "Adult" for full price' do
      expect(helper.price_category_label(Multiplier::FULL)).to eq('Adult')
    end

    it 'returns fractional adult for other multipliers' do
      expect(helper.price_category_label(3)).to eq('Adult x 1.5')
      expect(helper.price_category_label(4)).to eq('Adult x 2')
      expect(helper.price_category_label(5)).to eq('Adult x 2.5')
    end

    # The community form's words for the age rule: "Children under 5 eat free."
    it 'names a child who eats free as free, not as a multiple of an adult' do
      expect(helper.price_category_label(Multiplier::FREE)).to eq('Child (free)')
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

    # A settled dinner that was corrected (ADR 0011 rule 6) has two costs:
    # the one it was settled at, which the settlement's page shows, and
    # the one its rows add up to now, which the meal's own page shows.
    context 'when a settled dinner was corrected' do
      let(:latest) { Reconciliation.latest_cutoff(community.today) }
      let(:admin) { create(:admin_user, community: community, superuser: true) }
      let(:eater) { create(:resident, community: community, unit: unit) }
      let(:meal) do
        create(:meal, community: community, date: latest).tap do |meal|
          create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
          create(:meal_resident, meal: meal, resident: eater, community: community)
          settle!(cutoff: latest)
          MealCorrecting.save!(meal.reload, by: admin, reason: 'Typed the wrong amount', fingerprint: nil) do |edits|
            edits.cost(resident, amount: BigDecimal('20'), no_cost: false)
          end
        end.reload
      end

      it 'shows the settled cost when not asked for now' do
        expect(helper.meal_cost_cell(meal, :total_cost)).to eq('$30.00')
      end

      it 'shows the cost of the rows as they are now when asked for now' do
        expect(helper.meal_cost_cell(meal, :total_cost, now: true)).to eq('$20.00')
      end
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The serializer checks that are nowhere else. The calendar chips are
# pinned value by value in calendar_chips_spec.rb, and the key sets of
# the meal form, the attendance row and the guest row in
# api_contract_spec.rb.
RSpec.describe 'Serializers', type: :serializer do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  def serialize(object, serializer, params = {})
    serializer.new(object, params: params).to_h
  end

  describe MealFormSerializer::BillSerializer do
    # BigDecimal amounts must serialize as JSON strings, not floats.
    # Floats lose precision (0.1 + 0.2 != 0.3). This test ensures the
    # Oj Rails-mode encoder (Alba.backend in config/initializers/alba.rb)
    # keeps the string convention. If this test fails, financial data is
    # being silently corrupted in transit.
    # (Bill amounts are whole cents since issue #29, so the fixture is a
    # two-decimal value; the string-on-the-wire rule is what matters here.)
    it 'serializes BigDecimal amounts as strings, not floats' do
      meal = create(:meal, community: community)
      bill = create(:bill, meal: meal, resident: resident, community: community,
                           amount: BigDecimal('50.12'))

      json = described_class.new(bill).serialize
      parsed = JSON.parse(json)

      expect(parsed['amount']).to be_a(String)
      expect(BigDecimal(parsed['amount'])).to eq(BigDecimal('50.12'))
    end
  end

  describe RotationLogSerializer do
    # The sign-up sheet: everyone who can be asked to cook, whether or not
    # they signed up, and nobody else.
    it 'lists every resident who can cook, each marked signed up or not, with the unit before the name' do
      rotation = create(:rotation, community: community)
      meal = create(:meal, community: community, rotation: rotation)
      cook = create(:resident, community: community, unit: unit, name: 'Ann Cook')
      other = create(:resident, community: community, unit: unit, name: 'Bo Free')
      create(:resident, community: community, unit: unit, active: false)
      create(:resident, community: community, unit: unit, can_cook: false)
      create(:resident, community: community, unit: unit, multiplier: 1)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))

      # place_value is written by an after_commit with update_all, so the
      # object in memory does not have it until it is reloaded.
      rotation.reload
      result = serialize(rotation, described_class, cook_ids: rotation.cook_ids)

      expect(result.except(:residents)).to eq(id: rotation.id, place_value: 1, description: rotation.description)
      expect(result[:residents]).to contain_exactly(
        { id: cook.id, display_name: "#{unit.name} - Ann Cook", signed_up: true },
        { id: other.id, display_name: "#{unit.name} - Bo Free", signed_up: false }
      )
    end
  end
end

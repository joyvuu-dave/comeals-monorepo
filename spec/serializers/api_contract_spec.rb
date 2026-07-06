# frozen_string_literal: true

require 'rails_helper'

# Rails half of the API contract gate. The TypeScript half is
# tests/unit/api_contract.test.ts; both assert against the same fixture,
# tests/fixtures/api_contract.json. A serializer change that isn't mirrored
# in app/frontend/src/types/api.ts (or vice versa) fails bin/check instead
# of relying on same-PR discipline.
# See docs/adr/0001-typescript-at-the-api-boundary.md.
#
# Scope: serializer-backed response shapes only. Ack/BillsAck are inline
# controller hashes with no serializer to drift.
#
# These serialize real records (not serializer._attributes introspection) so
# adapter behavior — key names as actually rendered — is what's asserted.
RSpec.describe 'API contract (tests/fixtures/api_contract.json)', type: :serializer do
  contract = JSON.parse(Rails.root.join('tests/fixtures/api_contract.json').read)

  # Every fixture entry must be asserted below; a new entry without a matching
  # test here should fail loudly, not pass silently.
  covered = %w[MealForm MealFormBill MealFormResident MealFormGuest MealResident Guest]

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  def keys_of(hash)
    hash.keys.map(&:to_s).sort
  end

  it 'covers every entry in the contract fixture' do
    expect(covered).to match_array(contract.keys)
  end

  describe 'GET /api/v1/meals/:meal_id/cooks' do
    # Mirrors MealsController#show_cooks exactly: same serializer, same scope,
    # same meal_residents_lookup instance option.
    let(:meal_form) do
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('12.34'))
      create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:guest, meal: meal, resident: resident)

      lookup = meal.meal_residents.index_by(&:resident_id)
      ActiveModelSerializers::SerializableResource.new(
        meal, serializer: MealFormSerializer, scope: meal, meal_residents_lookup: lookup
      ).as_json
    end

    it 'matches MealForm' do
      expect(keys_of(meal_form)).to eq(contract.fetch('MealForm').sort)
    end

    it 'matches MealFormBill' do
      bill = meal_form.fetch(:bills).first
      expect(bill).to be_present
      expect(keys_of(bill)).to eq(contract.fetch('MealFormBill').sort)
    end

    it 'matches MealFormResident' do
      form_resident = meal_form.fetch(:residents).first
      expect(form_resident).to be_present
      expect(keys_of(form_resident)).to eq(contract.fetch('MealFormResident').sort)
    end

    it 'matches MealFormGuest' do
      guest = meal_form.fetch(:guests).first
      expect(guest).to be_present
      expect(keys_of(guest)).to eq(contract.fetch('MealFormGuest').sort)
    end
  end

  describe 'POST /api/v1/meals/:meal_id/residents/:resident_id' do
    it 'matches MealResident' do
      meal_resident = create(:meal_resident, meal: meal, resident: resident, community: community)
      result = ActiveModelSerializers::SerializableResource.new(
        meal_resident, serializer: MealResidentSerializer
      ).as_json

      expect(keys_of(result)).to eq(contract.fetch('MealResident').sort)
    end
  end

  describe 'POST /api/v1/meals/:meal_id/residents/:resident_id/guests' do
    it 'matches Guest' do
      guest = create(:guest, meal: meal, resident: resident)
      result = ActiveModelSerializers::SerializableResource.new(
        guest, serializer: GuestSerializer
      ).as_json

      expect(keys_of(result)).to eq(contract.fetch('Guest').sort)
    end
  end
end

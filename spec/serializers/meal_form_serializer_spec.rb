# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MealFormSerializer do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#residents' do
    it 'includes active residents' do
      active_resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).to include(active_resident.id)
    end

    it 'excludes inactive residents who did NOT attend' do
      inactive_nonattendee = create(:resident, community: community, unit: unit, active: false,
                                               multiplier: 2)
      meal = create(:meal, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).not_to include(inactive_nonattendee.id)
    end

    it 'includes inactive residents who DID attend (the bug fix)' do
      resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)

      # Resident attends meal while active
      create(:meal_resident, meal: meal, resident: resident, community: community)

      # Resident is later deactivated (moved/died)
      resident.update!(active: false)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).to include(resident.id)
    end

    it 'does not duplicate residents who are active AND attending' do
      resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      # Should appear exactly once, not duplicated by the OR
      expect(resident_ids.count(resident.id)).to eq(1)
    end
  end

  describe 'the links to the meals before and after' do
    it 'point at the nearest meal each way, and at the meal itself at either end' do
      first = create(:meal, community: community, date: Date.new(2026, 4, 5))
      middle = create(:meal, community: community, date: Date.new(2026, 4, 12))
      last = create(:meal, community: community, date: Date.new(2026, 4, 19))

      expect(described_class.new(middle).to_h).to include(prev_id: first.id, next_id: last.id, reconciled: false)
      expect(described_class.new(first).to_h).to include(prev_id: first.id, next_id: middle.id)
      expect(described_class.new(last).to_h).to include(prev_id: middle.id, next_id: last.id)
    end

    it 'says a settled meal is reconciled with a plain true' do
      meal = create(:meal, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect(described_class.new(meal).to_h[:reconciled]).to be(true)
    end
  end

  describe 'a resident row' do
    let(:home) { create(:unit, community: community, name: 'B7') }

    def row(meal, resident)
      described_class.new(meal).to_h.fetch(:residents).find { |r| r[:id] == resident.id }
    end

    it 'carries the attendance flags from the sign-up when there is one' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: home, name: 'Ann Lee', multiplier: 2,
                                   vegetarian: false, can_cook: true)
      attendance = create(:meal_resident, meal: meal, resident: resident, community: community, late: true,
                                          vegetarian: true)

      expect(row(meal, resident)).to eq(
        id: resident.id, meal_id: meal.id, name: 'B7 - Ann Lee', short_name: 'Ann Lee', attending: true,
        attending_at: attendance.created_at, late: true, vegetarian: true, can_cook: true, active: true
      )
    end

    it 'falls back to the resident\'s own diet, and no lateness, without a sign-up' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: home, name: 'Bea Ortiz', multiplier: 2,
                                   vegetarian: true)

      expect(row(meal, resident)).to include(attending: false, attending_at: nil, late: false, vegetarian: true)
    end
  end
end

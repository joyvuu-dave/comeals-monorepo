# frozen_string_literal: true

# == Schema Information
#
# Table name: guests
#
#  id          :bigint           not null, primary key
#  late        :boolean          default(FALSE), not null
#  multiplier  :integer          default(2), not null
#  vegetarian  :boolean          default(FALSE), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_guests_on_meal_id      (meal_id)
#  index_guests_on_resident_id  (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#

require 'rails_helper'

RSpec.describe Guest do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }

  describe '#cost' do
    it 'returns meal unit_cost multiplied by guest multiplier as BigDecimal' do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.reload

      # multiplier = 2 (from meal_resident)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      meal.reload

      guest = create(:guest, meal: meal, resident: resident)
      meal.reload

      # Total multiplier = 2 (meal_resident) + 2 (guest default) = 4
      # unit_cost = 50 / 4 = 12.5
      # guest.cost = 12.5 * 2 = 25
      expect(guest.cost).to be_a(BigDecimal)
      expect(guest.cost).to eq(BigDecimal('25'))
    end
  end

  describe '#meal_has_open_spots' do
    it 'allows guest when meal is open' do
      meal.update_columns(closed: false, max: nil)

      guest = described_class.new(meal: meal, resident: resident)
      guest.valid?

      expect(guest.errors[:base]).to be_empty
    end

    it 'rejects guest when meal is closed without max' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: nil)

      guest = described_class.new(meal: meal, resident: resident)
      guest.valid?

      expect(guest.errors[:base]).to include('Meal has been closed.')
    end

    it 'allows guest when meal is closed with max set and spots available' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 10)

      guest = described_class.new(meal: meal, resident: resident)
      guest.valid?

      expect(guest.errors[:base]).to be_empty
    end

    it 'errors when meal is closed with max set and no spots available' do
      # Create 2 attendees to fill the meal
      other_unit = create(:unit, community: community)
      filler_1 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      filler_2 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: filler_1, community: community)
      create(:guest, meal: meal, resident: filler_2, multiplier: 2)
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 2)

      guest = described_class.new(meal: meal, resident: resident)
      guest.valid?

      expect(guest.errors[:base]).to include('Meal has no open spots.')
    end

    it 'allows updating an existing guest when meal is closed at capacity' do
      other_unit = create(:unit, community: community)
      filler = create(:resident, community: community, unit: other_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: filler, community: community)
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2, vegetarian: false)
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 2)
      meal.reload

      guest.vegetarian = true
      expect(guest).to be_valid
      expect(guest.save).to be true
    end
  end

  describe '#destroy' do
    it 'blocks removal when guest was added before meal was closed' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect { guest.destroy }.not_to change(described_class, :count)
      expect(guest.errors[:base]).to include('Meal has been closed.')
    end

    it 'allows removal when guest was added after meal was closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      guest = create(:guest, meal: meal, resident: resident)

      expect { guest.destroy }.to change(described_class, :count).by(-1)
    end

    # Regression guard: closed meal with nil closed_at (possible via direct DB
    # writes) must fail closed, not open.
    it 'blocks removal gracefully when closed_at is nil on a closed meal' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: nil)

      expect { guest.destroy }.not_to change(described_class, :count)
      expect(guest.errors[:base]).to include('Meal has been closed.')
    end

    it 'blocks destruction when meal is reconciled' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect { guest.destroy }.not_to change(described_class, :count)
      expect(guest.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'allows destruction when meal is not reconciled' do
      guest = create(:guest, meal: meal, resident: resident)

      expect { guest.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe '#save (reconciled immutability)' do
    it 'blocks creating a new guest on a reconciled meal' do
      reconciliation = create(:reconciliation, community: community)
      meal.update!(reconciliation: reconciliation)

      guest = build(:guest, meal: meal, resident: resident)
      expect(guest.save).to be false
      expect(guest.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'blocks updating multiplier when meal is reconciled' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      guest.multiplier = 1
      expect(guest.save).to be false
      expect(guest.reload.multiplier).to eq(2)
    end

    it 'allows updates when meal is not reconciled' do
      guest = create(:guest, meal: meal, resident: resident, vegetarian: false)

      guest.vegetarian = true
      expect(guest.save).to be true
      expect(guest.reload.vegetarian).to be true
    end

    it 'blocks re-parenting a guest out of a reconciled meal' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update!(reconciliation: create(:reconciliation, community: community))
      unreconciled_meal = create(:meal, community: community)

      # The meal association now points at the NEW (unreconciled) meal — the
      # guard must still see that the OLD meal's ledger is closed.
      guest.meal = unreconciled_meal
      expect(guest.save).to be false
      expect(guest.errors[:base]).to include('Meal has been reconciled.')
      expect(guest.reload.meal_id).to eq(meal.id)
    end

    it 'blocks re-parenting a guest onto a reconciled meal' do
      guest = create(:guest, meal: meal, resident: resident)
      reconciled_meal = create(:meal, community: community)
      reconciled_meal.update!(reconciliation: create(:reconciliation, community: community))

      guest.meal = reconciled_meal
      expect(guest.save).to be false
      expect(guest.errors[:base]).to include('Meal has been reconciled.')
      expect(guest.reload.meal_id).to eq(meal.id)
    end
  end
end

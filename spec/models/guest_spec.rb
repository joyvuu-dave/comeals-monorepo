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

    # A meal loaded with its attendance (the admin form's) has the new guest
    # in its loaded list before validation runs, so the count must come from
    # the database, or the guest counts itself out of the last spot.
    it 'allows a guest on a closed meal with one spot open when the meal was loaded with its attendance' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 1)
      loaded = Meal.includes(:meal_residents, :guests).find(meal.id)
      guest = described_class.new(meal: loaded, resident: resident)

      expect(guest.save).to be(true)
    end

    it "counts this meal's attendance only, not another meal's" do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 1)
      other_meal = create(:meal, community: community, date: meal.date + 1)
      create(:meal_resident, meal: other_meal, resident: resident, community: community)
      create(:guest, meal: other_meal, resident: resident)

      expect(described_class.new(meal: Meal.find(meal.id), resident: resident).save).to be(true)
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

  # A move (meal_id changed on an existing row) is a removal from the old
  # meal and an addition to the new one; both rules apply.
  describe '#move_keeps_both_meals_rules' do
    let(:other_meal) { create(:meal, community: community, date: meal.date + 1) }

    it 'allows a move between two open meals' do
      guest = create(:guest, meal: meal, resident: resident)

      expect(guest.update(meal: other_meal)).to be(true)
      expect(guest.reload.meal_id).to eq(other_meal.id)
    end

    it 'refuses a move off a closed meal when the guest was on it before it closed' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(guest.update(meal: other_meal)).to be(false)
      expect(guest.errors[:base]).to include('Meal has been closed.')
      expect(guest.reload.meal_id).to eq(meal.id)
    end

    it 'allows a move off a closed meal when the guest was added after it closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      guest = create(:guest, meal: meal, resident: resident)

      expect(guest.update(meal: other_meal)).to be(true)
      expect(guest.reload.meal_id).to eq(other_meal.id)
    end

    it 'refuses a move onto a closed meal with no max' do
      guest = create(:guest, meal: meal, resident: resident)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago)

      expect(guest.update(meal: other_meal)).to be(false)
      expect(guest.errors[:base]).to include('Meal has been closed.')
      expect(guest.reload.meal_id).to eq(meal.id)
    end

    it 'refuses a move onto a closed meal with no open spots' do
      guest = create(:guest, meal: meal, resident: resident)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 1)
      create(:guest, meal: other_meal, resident: resident)

      expect(guest.update(meal: other_meal)).to be(false)
      expect(guest.errors[:base]).to include('Meal has no open spots.')
    end

    it 'allows a move onto a closed meal with a spot open' do
      guest = create(:guest, meal: meal, resident: resident)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 1)

      expect(guest.update(meal: other_meal)).to be(true)
      expect(guest.reload.meal_id).to eq(other_meal.id)
    end

    it 'answers with the old meal alone when both meals would refuse' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 1)
      create(:guest, meal: other_meal, resident: resident)

      expect(guest.update(meal: other_meal)).to be(false)
      expect(guest.errors[:base]).to eq(['Meal has been closed.'])
    end

    it 'lets an admin correction move a guest past both rules' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago)
      guest.admin_correction = true

      expect(guest.update(meal: other_meal)).to be(true)
      expect(guest.reload.meal_id).to eq(other_meal.id)
    end

    it 'does not run for an update that keeps the meal' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(guest.update(multiplier: 1)).to be(true)
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

    # A closed meal with no closed_at cannot exist: the database CHECK
    # meals_closed_at_matches_closed refuses it from every write path
    # (spec/db/closed_at_matches_closed_check_spec.rb).

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

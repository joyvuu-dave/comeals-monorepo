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

  # Issue #121. Both columns are NOT NULL. The model refuses a nil with a
  # sentence, so every path (API, admin, a task) gets a readable error
  # instead of the database's NotNullViolation. Nothing writes a guest's
  # late today, but its column refuses a nil too, so the model checks it.
  describe 'the vegetarian and late flags' do
    it 'refuses a nil vegetarian with a sentence' do
      guest = described_class.new(meal: meal, resident: resident, vegetarian: nil)

      expect(guest).not_to be_valid
      expect(guest.errors.full_messages).to eq(['Vegetarian must be true or false'])
    end

    it 'refuses a nil late with a sentence' do
      guest = described_class.new(meal: meal, resident: resident, late: nil)

      expect(guest).not_to be_valid
      expect(guest.errors.full_messages).to eq(['Late must be true or false'])
    end

    it 'accepts true and false for each flag' do
      [true, false].product([true, false]).each do |late, vegetarian|
        guest = described_class.new(meal: meal, resident: resident, late: late, vegetarian: vegetarian)

        expect(guest).to be_valid, "late: #{late}, vegetarian: #{vegetarian}: #{guest.errors.full_messages}"
      end
    end

    it 'takes the column default, false, when nothing sets the flags, as the admin meal form does' do
      guest = described_class.new(meal: meal, resident: resident)

      expect(guest).to have_attributes(late: false, vegetarian: false)
      expect(guest).to be_valid
    end

    it 'refuses a nil on an update and keeps the stored row' do
      guest = create(:guest, meal: meal, resident: resident, vegetarian: true)

      expect(guest.update(vegetarian: nil)).to be(false)
      expect(guest.errors.full_messages).to eq(['Vegetarian must be true or false'])
      expect(guest.reload.vegetarian).to be(true)
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
      guest = create(:guest, meal: meal, resident: resident, late: false)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(guest.update(late: true)).to be(true)
      expect(guest.reload.late).to be(true)
    end
  end

  # A guest's price is part of the headcount a closed meal freezes: moving
  # it from Adult to Child changes Meal#multiplier, so every other eater
  # pays more, the same as removing the guest would.
  describe 'a price change on a closed meal' do
    it 'refuses it for a guest who was on the meal before it closed' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(guest.update(multiplier: 1)).to be(false)
      expect(guest.errors[:base]).to eq(['Meal has been closed.'])
      expect(guest.reload.multiplier).to eq(2)
    end

    it 'allows it while the meal is open' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)

      expect(guest.update(multiplier: 1)).to be(true)
      expect(guest.reload.multiplier).to eq(1)
    end

    # An extra may leave a closed meal, so it may change its price too.
    it 'allows it for a guest added as an extra after the meal closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)

      expect(guest.update(multiplier: 1)).to be(true)
      expect(guest.reload.multiplier).to eq(1)
    end

    it 'lets an admin correction change the price of a guest who was on the meal before it closed' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)
      guest.admin_correction = true

      expect(guest.update(multiplier: 1)).to be(true)
      expect(guest.reload.multiplier).to eq(1)
    end

    # A move is judged by the move rule alone: on the new meal the guest is
    # an addition, and an addition may come with any price. The new meal
    # closes after the guest was made, so to the removal rule the guest
    # would look like one of that meal's original headcount.
    it 'judges a move with a new price as a move' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: 2)
      other_meal = create(:meal, community: community, date: meal.date + 1)
      other_meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour, max: 5)

      expect(guest.update(meal: other_meal, multiplier: 1)).to be(true)
      expect(guest.reload).to have_attributes(meal_id: other_meal.id, multiplier: 1)
    end
  end

  # A guest's share is charged to the host. A new host moves the whole
  # guest charge from one person to another, so on a closed meal it
  # follows the removal rule, the same as a price change. To fix a wrong
  # host, an admin reopens the meal, changes the host, and closes it again.
  describe 'a host change on a closed meal' do
    let(:new_host) { create(:resident, community: community, unit: unit) }

    it 'refuses it for a guest who was on the meal before it closed' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(guest.update(resident: new_host)).to be(false)
      expect(guest.errors[:base]).to eq(['Meal has been closed.'])
      expect(guest.reload.resident_id).to eq(resident.id)
    end

    it 'allows it while the meal is open' do
      guest = create(:guest, meal: meal, resident: resident)

      expect(guest.update(resident: new_host)).to be(true)
      expect(guest.reload.resident_id).to eq(new_host.id)
    end

    # An extra may leave a closed meal, so it may change its host too.
    it 'allows it for a guest added as an extra after the meal closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      guest = create(:guest, meal: meal, resident: resident)

      expect(guest.update(resident: new_host)).to be(true)
      expect(guest.reload.resident_id).to eq(new_host.id)
    end

    it 'lets an admin correction change the host of a guest who was on the meal before it closed' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)
      guest.admin_correction = true

      expect(guest.update(resident: new_host)).to be(true)
      expect(guest.reload.resident_id).to eq(new_host.id)
    end

    # A move is judged by the move rule alone, as with a new price: on the
    # new meal the guest is an addition, with any host.
    it 'judges a move with a new host as a move' do
      guest = create(:guest, meal: meal, resident: resident)
      other_meal = create(:meal, community: community, date: meal.date + 1)
      other_meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour, max: 5)

      expect(guest.update(meal: other_meal, resident: new_host)).to be(true)
      expect(guest.reload).to have_attributes(meal_id: other_meal.id, resident_id: new_host.id)
    end
  end

  # A guest pays as an adult or as a child, nothing else. The admin meal
  # form offers exactly these two, so it can always show the price a
  # guest has, and a save never changes a price nobody touched. Free is a
  # price only a resident's age gives. The guests_multiplier_adult_or_child
  # CHECK refuses the rest from writes that skip the model
  # (spec/db/guests_multiplier_check_spec.rb).
  describe 'the price' do
    it 'accepts Adult and Child' do
      [Multiplier::FULL, Multiplier::HALF].each do |multiplier|
        guest = described_class.new(meal: meal, resident: resident, multiplier: multiplier)

        expect(guest).to be_valid, "#{multiplier}: #{guest.errors.full_messages}"
      end
    end

    it 'refuses free, and every other number, with a sentence' do
      [Multiplier::FREE, 3, -1].each do |multiplier|
        guest = described_class.new(meal: meal, resident: resident, multiplier: multiplier)

        expect(guest).not_to be_valid
        expect(guest.errors.full_messages).to eq(['Multiplier must be 2 (Adult) or 1 (Child)']), multiplier.to_s
      end
    end

    it 'refuses a new price of free on an open meal and keeps the stored one' do
      guest = create(:guest, meal: meal, resident: resident, multiplier: Multiplier::HALF)

      expect(guest.update(multiplier: Multiplier::FREE)).to be(false)
      expect(guest.reload.multiplier).to eq(Multiplier::HALF)
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

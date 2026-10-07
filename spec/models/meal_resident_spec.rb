# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_residents
#
#  id           :bigint           not null, primary key
#  late         :boolean          default(FALSE), not null
#  multiplier   :integer          not null
#  vegetarian   :boolean          default(FALSE), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  meal_id      :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_meal_residents_on_meal_id_and_resident_id  (meal_id,resident_id) UNIQUE
#  index_meal_residents_on_resident_id              (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#

require 'rails_helper'

RSpec.describe MealResident do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }

  describe '#set_multiplier' do
    it "copies the resident's band for the meal's date before validation" do
      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.multiplier).to eq(resident.multiplier_on(meal.date))
      expect(mr.multiplier).to eq(Multiplier::FULL)
    end

    it "uses the meal's date, not today: a child who is full price by the meal pays full price" do
      # Turns 12 (the default full-price age) five days before the meal,
      # so today they are a child and on the meal's day an adult.
      meal.update!(date: community.today + 10)
      child = create(:resident, community: community, unit: unit,
                                birthday: community.today + 5 - 12.years)
      expect(child).to be_child

      mr = described_class.new(meal: meal, resident: child)
      mr.valid?

      expect(mr.multiplier).to eq(Multiplier::FULL)
    end

    it 'copies a child multiplier of 1' do
      child = create(:resident, community: community, unit: unit, multiplier: 1)
      mr = described_class.new(meal: meal, resident: child)
      mr.valid?

      expect(mr.multiplier).to eq(1)
    end

    it 'refuses a multiplier that is not the resident\'s, instead of replacing it' do
      child = create(:resident, community: community, unit: unit, multiplier: 1)
      mr = described_class.new(meal: meal, resident: child, community: community, multiplier: 2)

      expect(mr).not_to be_valid
      expect(mr.errors[:multiplier]).to include("must be the resident's price for the meal's date (1), not 2")
      expect(mr.multiplier).to eq(2)
    end

    it 'has no expected multiplier until it has both a resident and a meal' do
      expect(described_class.new(meal: meal).expected_multiplier).to be_nil
      expect(described_class.new(resident: resident).expected_multiplier).to be_nil
      expect(described_class.new(meal: meal, resident: resident).expected_multiplier).to eq(Multiplier::FULL)
    end

    it 'reports a missing resident, not a wrong multiplier' do
      mr = described_class.new(meal: meal, community: community, multiplier: 2)

      expect(mr).not_to be_valid
      expect(mr.errors[:resident]).to be_present
      expect(mr.errors[:multiplier]).to be_empty
    end

    it 'accepts the resident\'s own multiplier when it is given' do
      mr = described_class.new(meal: meal, resident: resident, community: community,
                               multiplier: resident.multiplier_on(meal.date))

      expect(mr).to be_valid
    end

    # The band check runs only on create. A later birthday change must not
    # block editing late or vegetarian on an old sign-up, and must not
    # change its multiplier. (set_multiplier only fills a missing value,
    # so it could not change this row on update either; the check that
    # would break is multiplier_is_the_residents without `on: :create`.)
    it 'preserves the original multiplier when the record is updated' do
      child = create(:resident, community: community, unit: unit, multiplier: 1)
      mr = create(:meal_resident, meal: meal, resident: child, community: community)
      expect(mr.multiplier).to eq(1)

      # The birthday is corrected: an adult after all.
      child.update!(birthday: 30.years.ago.to_date)

      expect(mr.update(late: true)).to be(true)
      expect(mr.errors).to be_empty
      expect(mr.reload.multiplier).to eq(1)
      expect(mr.late).to be(true)
    end

    it "captures the resident's band as of creation time" do
      # A resident whose birthday now says adult gets 2 on any NEW signup.
      promoted = create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date)
      mr = create(:meal_resident, meal: meal, resident: promoted, community: community)
      expect(mr.multiplier).to eq(2)
    end
  end

  # Issue #121. Both columns are NOT NULL. The model refuses a nil with a
  # sentence, so every path (API, admin, a task) gets a readable error
  # instead of the database's NotNullViolation.
  describe 'the late and vegetarian flags' do
    it 'refuses a nil late with a sentence' do
      mr = described_class.new(meal: meal, resident: resident, late: nil, vegetarian: false)

      expect(mr).not_to be_valid
      expect(mr.errors.full_messages).to eq(['Late must be true or false'])
    end

    it 'refuses a nil vegetarian with a sentence' do
      mr = described_class.new(meal: meal, resident: resident, late: false, vegetarian: nil)

      expect(mr).not_to be_valid
      expect(mr.errors.full_messages).to eq(['Vegetarian must be true or false'])
    end

    it 'accepts true and false for each flag' do
      [true, false].product([true, false]).each do |late, vegetarian|
        mr = described_class.new(meal: meal, resident: resident, late: late, vegetarian: vegetarian)

        expect(mr).to be_valid, "late: #{late}, vegetarian: #{vegetarian}: #{mr.errors.full_messages}"
      end
    end

    it 'takes the column default, false, when nothing sets the flags, as the admin create does' do
      mr = described_class.new(meal: meal, resident: resident)

      expect(mr).to have_attributes(late: false, vegetarian: false)
      expect(mr).to be_valid
    end

    it 'refuses a nil on an update and keeps the stored row' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: true, vegetarian: true)

      expect(mr.update(late: nil)).to be(false)
      expect(mr.errors.full_messages).to eq(['Late must be true or false'])
      expect(mr.reload).to have_attributes(late: true, vegetarian: true)
    end
  end

  describe '#meal_has_open_spots' do
    it 'allows signup when meal is open' do
      meal.update_columns(closed: false)

      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.errors[:base]).to be_empty
    end

    it 'allows signup when meal is closed with max set and spots available' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)

      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.errors[:base]).to be_empty
    end

    it 'rejects signup when meal is closed without max' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: nil)

      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.errors[:base]).to include('Meal has been closed.')
    end

    it 'rejects signup when meal is closed with max and no spots available' do
      # Create 2 attendees to fill the meal
      other_unit = create(:unit, community: community)
      attendee_1 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      attendee_2 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: attendee_1, community: community)
      create(:guest, meal: meal, resident: attendee_2, multiplier: 2)
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 2)

      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.errors[:base]).to include('Meal has no open spots.')
    end

    # Regression: when attendees_count already exceeds max (possible via admin
    # or console), the validation must still reject further signups.
    it 'rejects signup when attendees_count already exceeds max' do
      other_unit = create(:unit, community: community)
      attendee_1 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      attendee_2 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      attendee_3 = create(:resident, community: community, unit: other_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: attendee_1, community: community)
      create(:meal_resident, meal: meal, resident: attendee_2, community: community)
      create(:meal_resident, meal: meal, resident: attendee_3, community: community)
      # max=2 but 3 attendees already exist (set via update_columns to bypass validation)
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 2)
      meal.reload

      mr = described_class.new(meal: meal, resident: resident)
      mr.valid?

      expect(mr.errors[:base]).to include('Meal has no open spots.')
    end
  end

  # The freeze is shared with Guest; the full table of moves is in
  # spec/models/guest_spec.rb. These pin that an attendance row gets the
  # same answer.
  describe '#move_keeps_both_meals_rules' do
    let(:other_meal) { create(:meal, community: community, date: meal.date + 1) }

    it 'refuses a move off a closed meal when the resident signed up before it closed' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(mr.update(meal: other_meal)).to be(false)
      expect(mr.errors[:base]).to include('Meal has been closed.')
      expect(mr.reload.meal_id).to eq(meal.id)
    end

    it 'refuses a move onto a closed meal with no max' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      other_meal.update_columns(closed: true, closed_at: 1.hour.ago)

      expect(mr.update(meal: other_meal)).to be(false)
      expect(mr.errors[:base]).to include('Meal has been closed.')
    end

    it 'allows a move between two open meals' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)

      expect(mr.update(meal: other_meal)).to be(true)
      expect(mr.reload.meal_id).to eq(other_meal.id)
    end
  end

  describe '#record_can_be_removed' do
    it 'allows removal when meal is open' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)

      expect { mr.destroy }.to change(described_class, :count).by(-1)
    end

    it 'allows removal when resident signed up after meal was closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)

      expect { mr.destroy }.to change(described_class, :count).by(-1)
    end

    it 'blocks removal when resident signed up before meal was closed' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      # Set closed_at to after the meal_resident was created
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect { mr.destroy }.not_to change(described_class, :count)
      expect(mr.errors[:base]).to include('Meal has been closed.')
    end

    # A closed meal with no closed_at cannot exist: the database CHECK
    # meals_closed_at_matches_closed refuses it from every write path
    # (spec/db/closed_at_matches_closed_check_spec.rb). So there is no
    # "closed_at is nil" case to test here.

    it 'blocks removal when meal is reconciled' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect { mr.destroy }.not_to change(described_class, :count)
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
    end
  end

  # The admin_correction flag (issue #25) is the one sanctioned bypass of the
  # closed-meal freeze: an admin correcting the record to match reality. It
  # must never weaken the reconciled freeze — the books are closed.
  describe '#admin_correction' do
    it 'allows creating a row on a closed meal with no max' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: nil)

      mr = described_class.new(meal: meal, resident: resident, admin_correction: true)
      expect(mr.save).to be true
    end

    it 'allows removing an original-headcount row from a closed meal' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      mr.admin_correction = true
      expect { mr.destroy }.to change(described_class, :count).by(-1)
    end

    it 'still blocks creating a row on a reconciled meal' do
      meal.update!(reconciliation: create(:reconciliation, community: community))

      mr = described_class.new(meal: meal, resident: resident, admin_correction: true)
      expect(mr.save).to be false
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'still blocks removing a row from a reconciled meal' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      mr.admin_correction = true
      expect { mr.destroy }.not_to change(described_class, :count)
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
    end
  end

  describe '#save (reconciled immutability)' do
    it 'blocks creating a new meal_resident on a reconciled meal' do
      reconciliation = create(:reconciliation, community: community)
      meal.update!(reconciliation: reconciliation)

      mr = build(:meal_resident, meal: meal, resident: resident, community: community)
      expect(mr.save).to be false
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'blocks toggling late when meal is reconciled' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      mr.late = true
      expect(mr.save).to be false
      expect(mr.reload.late).to be false
    end

    it 'blocks toggling vegetarian when meal is reconciled' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community, vegetarian: false)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      mr.vegetarian = true
      expect(mr.save).to be false
      expect(mr.reload.vegetarian).to be false
    end

    it 'allows updates when meal is not reconciled' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)

      mr.late = true
      expect(mr.save).to be true
      expect(mr.reload.late).to be true
    end

    it 'blocks re-parenting an attendance row out of a reconciled meal' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))
      unreconciled_meal = create(:meal, community: community)

      # The meal association now points at the NEW (unreconciled) meal — the
      # guard must still see that the OLD meal's ledger is closed.
      mr.meal = unreconciled_meal
      expect(mr.save).to be false
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
      expect(mr.reload.meal_id).to eq(meal.id)
    end

    it 'blocks re-parenting an attendance row onto a reconciled meal' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      reconciled_meal = create(:meal, community: community)
      reconciled_meal.update!(reconciliation: create(:reconciliation, community: community))

      mr.meal = reconciled_meal
      expect(mr.save).to be false
      expect(mr.errors[:base]).to include('Meal has been reconciled.')
      expect(mr.reload.meal_id).to eq(meal.id)
    end
  end
end

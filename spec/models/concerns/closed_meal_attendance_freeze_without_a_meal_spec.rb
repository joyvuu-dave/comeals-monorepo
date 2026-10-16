# frozen_string_literal: true

require 'rails_helper'

# FINDING, red on purpose (2026-10-16, mutant survivors of the meal
# models). A sign-up or a guest with no meal should be refused in words
# by belongs_to, the way a bill with no meal is, and the way the
# CancelledDinnerFreeze and ReconciledMealImmutability comments say ("a
# row with no meal is refused by belongs_to"). Instead valid? raises
# TypeError, "Passed `nil` into T.must", from
# ClosedMealAttendanceFreeze#meal_has_open_spots, which calls
# refusal_to_join(T.must(meal)). No page of the app builds such a row;
# the console can.
RSpec.describe ClosedMealAttendanceFreeze do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  it 'lets belongs_to refuse a sign-up or a guest with no meal, in words, as for a bill' do
    bill = Bill.new(resident: resident, community: community, amount: 0)
    sign_up = MealResident.new(resident: resident, community: community)
    guest = Guest.new(resident: resident, multiplier: 2)

    expect(bill).not_to be_valid
    expect(bill.errors.full_messages).to include('Meal must exist')
    [sign_up, guest].each do |row|
      expect(row).not_to be_valid
      expect(row.errors.full_messages).to include('Meal must exist')
    end
  end

  it 'lets belongs_to refuse moving a sign-up or a guest to no meal, in words' do
    meal = create(:meal, community: community)
    sign_up = create(:meal_resident, meal: meal, resident: resident, community: community)
    guest = create(:guest, meal: meal, resident: resident)

    [sign_up, guest].each do |row|
      row.meal = nil
      expect(row).not_to be_valid
      expect(row.errors.full_messages).to include('Meal must exist')
    end
  end
end

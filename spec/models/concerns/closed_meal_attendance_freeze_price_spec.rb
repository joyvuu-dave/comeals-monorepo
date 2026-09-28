# frozen_string_literal: true

require 'rails_helper'

# A resident's price on a meal is copied when they sign up
# (Resident#multiplier_on). After that it changes only when an admin moves
# the meal to another date (Meal#restamp_attendance_for_new_date). No API
# or admin action writes it, but a console session can. On a closed meal
# the freeze refuses that change for anyone who was on the meal when it
# closed, because a lower price raises every other eater's share, the
# same as a removal (#92). The guest side, where the admin meal form
# offers a price, is in spec/models/guest_spec.rb.
RSpec.describe ClosedMealAttendanceFreeze do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  describe 'a resident price change on a closed meal' do
    it 'refuses it for a resident who was on the meal before it closed' do
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)

      expect(row.update(multiplier: Multiplier::HALF)).to be(false)
      expect(row.errors[:base]).to eq(['Meal has been closed.'])
      expect(row.reload.multiplier).to eq(Multiplier::FULL)
    end

    it 'allows it for a resident added as an extra after the meal closed' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      row = create(:meal_resident, meal: meal, resident: resident, community: community)

      expect(row.update(multiplier: Multiplier::HALF)).to be(true)
      expect(row.reload.multiplier).to eq(Multiplier::HALF)
    end

    it 'lets an admin correction through' do
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update_columns(closed: true, closed_at: DateTime.now + 1.hour)
      row.admin_correction = true

      expect(row.update(multiplier: Multiplier::HALF)).to be(true)
      expect(row.reload.multiplier).to eq(Multiplier::HALF)
    end
  end
end

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

class Guest < ApplicationRecord
  belongs_to :meal, inverse_of: :guests, touch: true
  belongs_to :resident

  audited associated_with: :meal

  # A guest can't be added, altered, or removed after settlement.
  include ReconciledMealImmutability
  # Nor added to or removed from a closed (but unsettled) meal, beyond the
  # host's explicit extras. Included after ReconciledMealImmutability so the
  # reconciled check runs first.
  include ClosedMealAttendanceFreeze

  validates :multiplier, numericality: { only_integer: true }

  def cost
    meal.unit_cost * multiplier
  end
end

# typed: true
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

class MealResident < ApplicationRecord
  include BelongsToTheCommunity

  belongs_to :meal, inverse_of: :meal_residents, touch: true
  belongs_to :resident

  audited associated_with: :meal

  # No new attendees, no toggling late/vegetarian, no removals once reconciled.
  include ReconciledMealImmutability
  # Nor signups on or removals from a closed (but unsettled) meal, beyond the
  # host's explicit extras. Included after ReconciledMealImmutability so the
  # reconciled check runs first.
  include ClosedMealAttendanceFreeze
  include NotesMealLiveUpdate

  before_validation :set_multiplier, on: :create

  validates :meal_id, uniqueness: { scope: :resident_id }
  validates :multiplier, numericality: { only_integer: true }

  def set_multiplier
    self.multiplier = resident&.multiplier
  end
end

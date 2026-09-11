# typed: strict
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
  extend T::Sig

  include BelongsToTheCommunity

  belongs_to :meal, inverse_of: :meal_residents, touch: true
  belongs_to :resident

  audited associated_with: :meal

  # Before every other guard: the meal lock comes first, so the checks
  # below read the meal under it. See the concern for the lock order.
  include LocksItsMealFirst

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
  validate :multiplier_is_the_residents, on: :create

  # The multiplier is the resident's at signup, copied so a later change to
  # the resident never changes a past charge. Nothing in production passes
  # one: the API assigns late and vegetarian, the admin create takes a
  # resident id. So a value given here is filled in when missing and refused
  # when different. It used to be replaced silently, and 76 spec lines
  # passed a value that did nothing (2026-09-09).
  sig { void }
  def set_multiplier
    self.multiplier = resident&.multiplier if multiplier.nil?
  end

  sig { void }
  def multiplier_is_the_residents
    expected = resident&.multiplier
    return if expected.nil? || multiplier == expected

    errors.add(:multiplier, "must be the resident's multiplier at signup (#{expected}), not #{multiplier}")
  end
end

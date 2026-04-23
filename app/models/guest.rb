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

  validates :multiplier, numericality: { only_integer: true }
  validate :meal_has_open_spots, on: :create
  # Reconciled meals are immutable. Blocks create, update, and destroy —
  # ensures a guest can't be added, altered, or removed after settlement.
  before_save :reject_if_reconciled
  before_destroy :reject_if_reconciled

  def meal_has_open_spots
    errors.add(:base, 'Meal has no open spots.') unless meal.max.nil? || meal.attendees_count < meal.max
  end

  def reject_if_reconciled
    return unless meal&.reconciled?

    errors.add(:base, 'Meal has been reconciled.')
    throw(:abort)
  end

  def cost
    meal.unit_cost * multiplier
  end
end

# typed: strict
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

  # Prepended before_save and before_destroy: the meal lock is taken
  # before the row is written, in the trigger's order. The validations
  # below run earlier than any before_save, so they do not read under this
  # lock (the reconciled guard reads the row again in its before_save,
  # which does); the SERIALIZABLE transaction they share with the write
  # keeps their answer and the write together. See the concern.
  include LocksItsMealFirst

  # A guest can't be added, altered, or removed after settlement.
  include ReconciledMealImmutability
  # Nor added to or removed from a closed (but unsettled) meal, beyond the
  # host's explicit extras. Included after ReconciledMealImmutability so the
  # reconciled check runs first.
  include ClosedMealAttendanceFreeze
  include NotesMealLiveUpdate

  # The integer check refuses 1.5, which the column would otherwise cut to
  # 1 without a word. The list is the two guest prices (Multiplier); the
  # guests_multiplier_adult_or_child CHECK holds the same rule for writes
  # that skip the model.
  validates :multiplier, numericality: { only_integer: true }
  validates :multiplier, inclusion: { in: Multiplier::GUEST_PRICES, message: 'must be 2 (Adult) or 1 (Child)' }
  # Both columns are NOT NULL. Without this a nil (a guest sent without
  # vegetarian) reached the database and the API answered 500 (#121).
  # Nothing writes late today. It is checked anyway, because its column
  # refuses a nil too.
  validates :vegetarian, :late, inclusion: { in: [true, false], message: TrueOrFalse::MESSAGE }
end

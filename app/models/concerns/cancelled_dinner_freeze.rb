# typed: true
# frozen_string_literal: true

# The sign-ups, guests and costs of a cancelled dinner stay as they were
# when it was cancelled (ADR 0011 rule 11). They are the record of who
# meant to come, and a cancelled dinner charges nobody, so a change to
# them changes nothing but the record. Restoring the dinner lets them
# change again.
#
# The same three hooks as ReconciledMealImmutability, and it reads the
# meals table the same way, never the row's loaded meal: someone may have
# cancelled or restored the dinner since the row was loaded, and the meal
# lock LocksItsMealFirst takes makes that read the one that counts. Both
# meals are checked when a row moves to another meal. Included after
# ReconciledMealImmutability, so a settled dinner says it is settled, and
# before ClosedMealAttendanceFreeze, so a cancelled dinner that is also
# closed says it is cancelled. The trigger comeals_reject_settled_child_write
# holds the same rule for a write that skips the model.
module CancelledDinnerFreeze
  extend ActiveSupport::Concern
  extend T::Helpers
  extend T::Sig

  requires_ancestor { ApplicationRecord }

  MESSAGE = 'This dinner is cancelled. Restore it before changing it.'

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    validate :refuse_if_dinner_cancelled, on: %i[create update]
    before_save :reject_if_dinner_cancelled
    before_destroy :reject_if_dinner_cancelled
  end

  # The validation: adds the sentence and lets the other validations run.
  def refuse_if_dinner_cancelled
    errors.add(:base, MESSAGE) if either_dinner_cancelled?
  end

  # The callback: stops the write here, before the trigger has to.
  def reject_if_dinner_cancelled
    return unless either_dinner_cancelled?

    errors.add(:base, MESSAGE) unless errors.added?(:base, MESSAGE)
    throw(:abort)
  end

  private

  # The meal the row has now, and the one it has in the database: the
  # same meal unless the row moves. A nil matches no meal (Rails reads it
  # as IS NULL): a row with no meal is refused by belongs_to, and a new
  # row has no meal in the database.
  sig { returns(T::Boolean) }
  def either_dinner_cancelled?
    Meal.where(id: [meal_id, meal_id_in_database]).where.not(cancelled_at: nil).exists?
  end
end

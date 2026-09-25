# typed: true
# frozen_string_literal: true

# Rows that feed a meal's settlement (bills, attendance) are immutable once
# the meal is reconciled — accounting principle: no edits to a closed ledger.
# Blocks create, update, and destroy across API, ActiveAdmin, and console
# paths, and checks BOTH meals when meal_id is being reassigned: the current
# meal_id (the NEW meal) and the previously persisted one, so a row can be
# moved neither onto nor out of a settled meal.
#
# It reads the meals table, never the row's `meal` association. The
# association holds whatever meal the row was loaded with: the admin
# controller loads it to decide whether to allow the write, and a
# settlement can claim the meal between that read and the save. Reading
# the cached meal let such a write reach the database trigger, which
# refused it with an exception instead of this sentence (lock hunt,
# 2026-09-21).
#
# Three hooks, one rule. The validation runs on create and update, before
# the closed-meal freeze's validations because this concern is included
# first, so "Meal has been reconciled." is the sentence a person sees
# even when the meal is also closed. The before_save covers a save that
# skips validation. The before_destroy runs first among the destroy
# guards for the same include-order reason. A settlement that commits
# during the save is not this concern's job: at SERIALIZABLE the lock
# LocksItsMealFirst takes on the changed meal row raises a serialization
# failure, and the caller retries or shows "try again".
module ReconciledMealImmutability
  extend ActiveSupport::Concern
  extend T::Helpers
  extend T::Sig

  requires_ancestor { ApplicationRecord }

  MESSAGE = 'Meal has been reconciled.'

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    validate :refuse_if_reconciled, on: %i[create update]
    before_save :reject_if_reconciled
    before_destroy :reject_if_reconciled
  end

  # The validation: adds the sentence and lets the other validations run.
  def refuse_if_reconciled
    errors.add(:base, MESSAGE) if either_meal_reconciled?
  end

  # The callback: stops the write here, before the trigger has to.
  def reject_if_reconciled
    return unless either_meal_reconciled?

    errors.add(:base, MESSAGE) unless errors.added?(:base, MESSAGE)
    throw(:abort)
  end

  private

  # A row with no meal is refused by belongs_to before it gets anywhere
  # near a settlement; nil here is that case, not a settled meal.
  sig { returns(T::Boolean) }
  def either_meal_reconciled?
    id = meal_id
    return false if id.nil?

    reconciled_in_database?(id) || previous_meal_reconciled?
  end

  sig { returns(T::Boolean) }
  def previous_meal_reconciled?
    old_meal_id = meal_id_in_database
    return false unless will_save_change_to_meal_id? && old_meal_id.present?

    reconciled_in_database?(old_meal_id)
  end

  sig { params(id: Integer).returns(T::Boolean) }
  def reconciled_in_database?(id)
    Meal.where(id: id).pick(:reconciliation_id).present?
  end
end

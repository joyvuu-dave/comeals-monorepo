# frozen_string_literal: true

# Rows that feed a meal's settlement (bills, attendance) are immutable once
# the meal is reconciled — accounting principle: no edits to a closed ledger.
# Blocks create, update, and destroy across API, ActiveAdmin, and console
# paths, and checks BOTH meals when meal_id is being reassigned: the current
# association (which points at the NEW meal) and the previously persisted
# one, so a row can be moved neither onto nor out of a settled meal.
#
# Include BEFORE any other before_destroy declaration so the reconciled
# check always runs first.
module ReconciledMealImmutability
  extend ActiveSupport::Concern

  included do
    before_save :reject_if_reconciled
    before_destroy :reject_if_reconciled
  end

  def reject_if_reconciled
    return unless meal.reconciled? || previous_meal_reconciled?

    errors.add(:base, 'Meal has been reconciled.')
    throw(:abort)
  end

  private

  def previous_meal_reconciled?
    return false unless will_save_change_to_meal_id? && meal_id_in_database.present?

    Meal.find(meal_id_in_database).reconciled?
  end
end

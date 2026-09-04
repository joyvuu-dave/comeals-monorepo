# typed: true
# frozen_string_literal: true

# Closing a meal freezes its headcount — attendance rows (MealResident,
# Guest) feed Meal#multiplier and unit_cost, so late additions or removals
# silently shift every other attendee's charge. The only sanctioned
# exceptions, in both directions, are the "extras" the host explicitly
# opens up by setting max:
#
#   * additions are allowed while max is set and spots remain;
#   * removals are allowed only for rows created after the meal closed
#     (an extra backing out), never for the original headcount.
#
# An open meal always has max nil (Meal#conditionally_set_max), so max
# only ever constrains closed meals.
#
# Include AFTER ReconciledMealImmutability so the reconciled check — the
# stronger, settlement-level freeze — always runs first.
module ClosedMealAttendanceFreeze
  extend ActiveSupport::Concern
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  # The one sanctioned bypass (issue #25): an admin correcting the record
  # to match reality. Set per row by the ActiveAdmin attendance controller,
  # never persisted, never assignable through the API (its controllers
  # assign only late/vegetarian). Reconciled meals still refuse —
  # ReconciledMealImmutability runs first and has no bypass.
  attr_accessor :admin_correction

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    validate :meal_has_open_spots, on: :create
    before_destroy :record_can_be_removed
  end

  def meal_has_open_spots
    # Scenario: Admin attendance correction — the freeze does not apply
    return true if admin_correction

    meal = T.must(self.meal)

    # Scenario: Meal is open
    return true if meal.closed == false

    # Scenario: Meal is closed and max has NOT been set
    max = meal.max
    return errors.add(:base, 'Meal has been closed.') if max.nil?

    # Scenario: Meal is closed, max has been set, there are open spots
    return true if meal.attendees_count < max

    # Scenario: Meal is closed, max has been set, there are NOT open spots
    errors.add(:base, 'Meal has no open spots.')
  end

  def record_can_be_removed
    # Reconciled check is handled by reject_if_reconciled (runs first).
    # Scenario: Admin attendance correction — the freeze does not apply
    return true if admin_correction

    meal = T.must(self.meal)

    # Scenario: Meal is open
    return true if meal.closed == false

    # Scenario: Meal is closed, record was added after meal was closed (there were extras)
    closed_at = meal.closed_at
    return true if meal.closed == true && closed_at.present? && T.must(created_at) > closed_at

    # Scenario: Meal is closed, record was added before meal was closed
    errors.add(:base, 'Meal has been closed.')
    throw(:abort)
  end
end

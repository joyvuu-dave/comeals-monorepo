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
#     (an extra backing out), never for the original headcount;
#   * a row moved to another meal (meal_id changed on an existing row) is
#     a removal from the old meal and an addition to the new one, and both
#     rules apply. Nothing in the app moves a row on purpose, but the
#     admin meal form once let a hand-made request do it (lock hunt,
#     2026-09-21), and a console session can still ask for one and gets
#     the same answer;
#   * a price change (multiplier) follows the removal rule. Moving a guest
#     from Adult to Child lowers Meal#multiplier, so every other eater pays
#     more, the same as when the guest leaves (#92). The admin meal form
#     offers a price for every guest;
#   * a change of who the row charges (resident_id: a guest's host, or the
#     person on an attendance row) follows the removal rule too. It moves a
#     whole share from one person to another. The admin meal form offers
#     a host for every guest. Nothing in the app changes the person on an
#     attendance row, but a console session can. To fix a wrong host, an
#     admin reopens the meal, changes the host, and closes it again.
#
# An open meal always has max nil (Meal#conditionally_set_max), so max
# only ever constrains closed meals.
#
# Include AFTER ReconciledMealImmutability so the reconciled check — the
# stronger, settlement-level freeze — runs first: its validation before
# these validations, its before_destroy before this before_destroy.
module ClosedMealAttendanceFreeze
  extend ActiveSupport::Concern
  extend T::Helpers
  extend T::Sig

  requires_ancestor { ApplicationRecord }

  # The one sanctioned bypass (issue #25): an admin correcting the record
  # to match reality. Set per row by the ActiveAdmin attendance controller,
  # and by Meal#restamp_attendance_for_new_date when an admin moves a meal
  # to another date. Never persisted, never assignable through the API (its
  # controllers assign only late/vegetarian). Reconciled meals still
  # refuse — ReconciledMealImmutability runs first and has no bypass.
  attr_accessor :admin_correction

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    validate :meal_has_open_spots, on: :create
    validate :move_keeps_both_meals_rules, on: :update
    validate :price_change_is_allowed, on: :update
    validate :resident_change_is_allowed, on: :update
    before_destroy :record_can_be_removed
  end

  def meal_has_open_spots
    # Scenario: Admin attendance correction — the freeze does not apply
    return if admin_correction

    message = refusal_to_join(T.must(meal))
    errors.add(:base, message) if message
  end

  # A move is a removal from the meal the row is on in the database and an
  # addition to the meal it is being saved with. The old meal is read from
  # the database, because the association holds the new one. Like every
  # validation this runs before the before_save where LocksItsMealFirst
  # takes its lock, in the same SERIALIZABLE transaction as the write; a
  # close of either meal that runs at the same time is ordered before or
  # after the whole of this write, never between the check and the write.
  def move_keeps_both_meals_rules
    return unless meal_id_changed?
    # Scenario: Admin attendance correction — the freeze does not apply
    return if admin_correction

    old_meal = Meal.find(T.must(meal_id_in_database))
    return errors.add(:base, 'Meal has been closed.') unless can_leave?(old_meal)

    message = refusal_to_join(T.must(meal))
    errors.add(:base, message) if message
  end

  # A move is left to move_keeps_both_meals_rules: on the new meal the row
  # is an addition, and an addition may have any price.
  def price_change_is_allowed
    return unless multiplier_changed?
    return if meal_id_changed?
    # Scenario: Admin attendance correction — the freeze does not apply
    return if admin_correction
    return if can_leave?(T.must(meal))

    # Scenario: Meal is closed, record was added before meal was closed
    errors.add(:base, 'Meal has been closed.')
  end

  # A move is left to move_keeps_both_meals_rules, as for a price change:
  # on the new meal the row is an addition, with any resident.
  def resident_change_is_allowed
    return unless resident_id_changed?
    return if meal_id_changed?
    # Scenario: Admin attendance correction — the freeze does not apply
    return if admin_correction
    return if can_leave?(T.must(meal))

    # Scenario: Meal is closed, record was added before meal was closed
    errors.add(:base, 'Meal has been closed.')
  end

  def record_can_be_removed
    # Reconciled check is handled by reject_if_reconciled (a before_destroy
    # declared before this one, so it runs first among the guards).
    # Scenario: Admin attendance correction — the freeze does not apply
    return if admin_correction
    return if can_leave?(T.must(meal))

    # Scenario: Meal is closed, record was added before meal was closed
    errors.add(:base, 'Meal has been closed.')
    throw(:abort)
  end

  private

  # The sentence that refuses a row joining this meal, or nil when it may.
  sig { params(meal: Meal).returns(T.nilable(String)) }
  def refusal_to_join(meal)
    # Scenario: Meal is open
    return nil if meal.closed == false

    # Scenario: Meal is closed and max has NOT been set
    max = meal.max
    return 'Meal has been closed.' if max.nil?

    # Scenario: Meal is closed, max has been set, there are open spots.
    # Counted in the database, not from the meal's loaded associations:
    # Rails puts a new or moved row into the target's loaded guests or
    # meal_residents as soon as its meal is assigned, before this runs, so
    # Meal#attendees_count on a preloaded meal (the admin form's) counted
    # the row itself and refused the last open spot (review, 2026-09-24).
    return nil if attendees_in_database(meal) < max

    # Scenario: Meal is closed, max has been set, there are NOT open spots
    'Meal has no open spots.'
  end

  sig { params(meal: Meal).returns(Integer) }
  def attendees_in_database(meal)
    MealResident.where(meal_id: meal.id).count + Guest.where(meal_id: meal.id).count
  end

  # Whether this row may leave this meal: the meal is open, or the row was
  # added after the meal closed (there were extras).
  sig { params(meal: Meal).returns(T::Boolean) }
  def can_leave?(meal)
    # Scenario: Meal is open
    return true if meal.closed == false

    # Scenario: Meal closes in this same save (the admin form's Closed box
    # with a guest's new price or host). The close happens now, so every
    # row already on the meal was there before it. This also has to come
    # before the closed_at check below: Meal#conditionally_set_closed_at
    # sets closed_at in a before_save, after this validation, so it is
    # still nil here.
    return false if meal.closed_in_database == false

    # The meal is closed in the database here. A closed meal always has
    # closed_at: Meal#conditionally_set_closed_at sets it, on create as
    # well as on close, and the database CHECK
    # meals_closed_at_matches_closed refuses a closed meal without one from
    # every write path. So T.must, not a nil branch: if it is ever nil the
    # data is corrupt and raising is right.
    T.must(created_at) > T.must(meal.closed_at)
  end
end

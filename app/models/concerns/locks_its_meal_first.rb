# typed: true
# frozen_string_literal: true

# A row that belongs to a meal (a bill, an attendance row, a guest) takes
# the meal's lock before it writes itself.
#
# The settled-meal trigger already locks the meal from inside every write
# to these tables (comeals_reject_settled_child_write, migration
# 20260727120000): it reads meals FOR KEY SHARE so an unlocked write waits
# for a running settlement and is then refused. But a trigger fires on the
# row write, which means the row lock is taken first and the meal lock
# second. The API locks them the other way round — the meal row with
# FOR UPDATE, then the child row (Api::V1::MealsController#with_meal_lock).
# Two lock orders on the same pair is a deadlock, and a request storm
# found it: an admin bill edit held the bill and waited for the meal while
# an API bills save held the meal and waited for that bill. PostgreSQL
# broke it after a second, both sides said "try again", and nothing was
# lost — but a wait is better than an abort, and one order everywhere is
# what turns the second into the first.
#
# So this takes the trigger's own lock, before the row instead of after
# it. FOR KEY SHARE, exactly what the trigger asks for, for two reasons:
# the trigger's later request is then already held, and two writes to
# different rows of one meal still run at the same time — only a writer
# that wants the whole meal (a settlement's FOR UPDATE, the API's
# with_lock) makes them wait.
#
# Both meals when meal_id is changing, in id order, so two writers moving
# rows between the same two meals cannot deadlock against each other
# either. Same reason Settlement#assign_meals orders its claim by id.
#
# Prepended, so it runs before every other guard: ReconciledMealImmutability
# then reads the meal under this lock instead of from a stale snapshot.
#
# Pinned by spec/requests/admin/meal_lock_order_spec.rb.
module LocksItsMealFirst
  extend ActiveSupport::Concern
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    before_save :lock_its_meals, prepend: true
    before_destroy :lock_its_meals, prepend: true
  end

  private

  # No guard for an empty list: belongs_to :meal is required, so a row
  # being saved or destroyed always has one, and an empty WHERE would be a
  # harmless no-op anyway.
  def lock_its_meals
    ids = [meal_id, meal_id_in_database].compact.uniq.sort
    Meal.where(id: ids).order(:id).lock('FOR KEY SHARE').pluck(:id)
  end
end

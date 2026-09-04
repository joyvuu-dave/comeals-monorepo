# typed: false
# frozen_string_literal: true

# A row that belongs to a meal and shows on its page and on the calendar
# (a bill, an attendance row, a guest). Any write to it, from any path,
# marks the meal's page and its calendar month stale — see LiveUpdate.
# `touch: true` on the belongs_to bumps meals.updated_at but runs none
# of the meal's save callbacks, so the row has to note itself.
module NotesMealLiveUpdate
  extend ActiveSupport::Concern

  included do
    after_save :note_meal_live_update
    after_destroy :note_meal_live_update
  end

  private

  def note_meal_live_update
    LiveUpdate.meal(meal_id)
    LiveUpdate.calendar(meal.date)
    old_meal_id = saved_changes.dig('meal_id', 0)
    return unless old_meal_id

    LiveUpdate.meal(old_meal_id)
    old_date = Meal.where(id: old_meal_id).pick(:date)
    LiveUpdate.calendar(old_date) if old_date
  end
end

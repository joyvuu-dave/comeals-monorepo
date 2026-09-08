# typed: true
# frozen_string_literal: true

# A row that belongs to a meal and shows on its page and on the calendar
# (a bill, an attendance row, a guest). Any write to it, from any path,
# marks the meal's page and its calendar month stale — see LiveUpdate.
# `touch: true` on the belongs_to bumps meals.updated_at but runs none
# of the meal's save callbacks, so the row has to note itself.
module NotesMealLiveUpdate
  extend ActiveSupport::Concern
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    after_save :note_meal_live_update
    after_destroy :note_meal_live_update
  end

  private

  def note_meal_live_update
    LiveUpdate.meal(meal_id)
    LiveUpdate.calendar(T.must(meal).date)
    old_meal_id = saved_changes.dig('meal_id', 0)
    return unless old_meal_id

    LiveUpdate.meal(old_meal_id)
    # The old meal is still there: the foreign key refused to delete it
    # while this row pointed at it. LiveUpdate.calendar ignores nil anyway.
    LiveUpdate.calendar(Meal.where(id: old_meal_id).pick(:date))
  end
end

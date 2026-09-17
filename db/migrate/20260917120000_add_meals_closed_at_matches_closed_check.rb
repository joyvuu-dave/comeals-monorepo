# frozen_string_literal: true

# closed_at is the "extras" boundary: an attendance row created after it
# may back out of a closed meal, a row created before it may not
# (ClosedMealAttendanceFreeze#record_can_be_removed). Until now the only
# thing keeping closed and closed_at in step was Meal's before_save, so a
# write that skips the model (update_columns, update_all, a rake task,
# psql) could leave a closed meal with no timestamp, and then no extra
# could ever back out of it. This CHECK makes that state impossible:
# a closed meal has a timestamp, an open meal has none. Every row in
# production already satisfies it.
class AddMealsClosedAtMatchesClosedCheck < ActiveRecord::Migration[8.1]
  def change
    # safety_assured: strong_migrations wants the constraint added
    # unvalidated and validated in a second migration, to avoid a long
    # lock on a big table. meals has about a thousand rows; validation
    # is instant.
    safety_assured do
      add_check_constraint :meals, 'closed = (closed_at IS NOT NULL)',
                           name: 'meals_closed_at_matches_closed'
    end
  end
end

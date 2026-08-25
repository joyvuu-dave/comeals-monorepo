# frozen_string_literal: true

# Both columns were copies of the rotation's meals (first date; the date
# range as words), filled in the rotation's own after_save. A meal write
# never saved the rotation, so deleting or moving the first meal left them
# stale (invariant hunt, 2026-08-25). Rotation#start_date and #description
# now read the meals every time.
class DropRotationStartDateAndDescription < ActiveRecord::Migration[8.1]
  def change
    # strong_migrations: Rotation lists both in ignored_columns, so a process
    # still running the old code never selects them.
    safety_assured do
      remove_column :rotations, :start_date, :date
      remove_column :rotations, :description, :string, default: '', null: false
    end
  end
end

# frozen_string_literal: true

# Every meal belongs to a rotation (#100). This is step 1 of 2, the way
# strong_migrations asks for NOT NULL on a column that already has rows:
# a CHECK added NOT VALID refuses a new NULL at once, without reading
# the rows already there. Step 2 (20261007153100) checks the existing
# rows, sets NOT NULL, and drops this CHECK. Its comment says what a
# rollback to v613 means.
class AddMealsRotationIdNullCheck < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :meals, 'rotation_id IS NOT NULL', name: 'meals_rotation_id_null', validate: false
  end
end

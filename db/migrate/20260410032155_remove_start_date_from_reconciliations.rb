# frozen_string_literal: true

class RemoveStartDateFromReconciliations < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :reconciliations, name: 'reconciliations_date_range_valid'
    remove_column :reconciliations, :start_date
  end

  def down
    add_column :reconciliations, :start_date, :date

    # Backfill from the earliest meal date in each reconciliation
    execute <<~SQL.squish
      UPDATE reconciliations SET start_date = COALESCE(
        (SELECT MIN(meals.date) FROM meals WHERE meals.reconciliation_id = reconciliations.id),
        reconciliations.end_date
      )
    SQL

    change_column_null :reconciliations, :start_date, false
    add_check_constraint :reconciliations, 'start_date <= end_date', name: 'reconciliations_date_range_valid'
  end
end

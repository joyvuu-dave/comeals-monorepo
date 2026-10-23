# frozen_string_literal: true

# A resident's price band is computed from the birthday since #88
# (Resident#multiplier_on), and nothing has read or written this column
# since then. It stayed one release so a rollback to the code before #88
# could still read it. That release (v618) is deployed, so the column goes
# (#89).
class DropResidentsMultiplier < ActiveRecord::Migration[8.1]
  def change
    # strong_migrations: Resident lists the column in ignored_columns in the
    # release running when this migration runs, so it never selects it.
    safety_assured do
      remove_check_constraint :residents, 'multiplier >= 0', name: 'residents_multiplier_non_negative'
      remove_column :residents, :multiplier, :integer, default: 2, null: false
    end
  end
end

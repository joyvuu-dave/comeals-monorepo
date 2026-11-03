# frozen_string_literal: true

# The login of the shared screen in the Common House. It is not a
# resident: it never cooks, eats or owes money, so nothing that lists
# residents can list it. Only admins know its password.
#
# - singleton_guard: always 0 (the CHECK), with a unique index, so the
#   table holds at most one row, the same rule as communities.
# - password_digest: an scrypt digest, as residents.password_digest.
# - keys_valid_since: a token made before this time is refused, as
#   residents.keys_valid_since. A password change moves it forward,
#   which signs the screen out.
#
# The previous release's code never reads this table, so it runs beside
# this migration without a change.
class CreateCommonHouseLogins < ActiveRecord::Migration[8.1]
  def change
    create_table :common_house_logins do |t|
      t.integer :singleton_guard, null: false, default: 0
      t.string :password_digest, null: false
      t.datetime :keys_valid_since, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.timestamps
    end
    add_index :common_house_logins, :singleton_guard, unique: true
    add_check_constraint :common_house_logins, 'singleton_guard = 0',
                         name: 'common_house_logins_singleton_guard_is_zero'
  end
end

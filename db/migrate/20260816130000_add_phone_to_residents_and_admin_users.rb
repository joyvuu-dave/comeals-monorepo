# frozen_string_literal: true

# One nullable phone column each for residents and admins, stored in E.164
# format: "+", country code, then digits, 15 digits at most ("+15105552671").
# The model (HasPhoneNumber) accepts any way of typing a number and saves
# this one canonical form. The CHECK keeps other forms out through writes
# that skip the model (update_all, rake tasks, psql — see CLAUDE.md): the
# stored value is either NULL or shaped like E.164.
class AddPhoneToResidentsAndAdminUsers < ActiveRecord::Migration[8.1]
  E164 = "phone IS NULL OR phone ~ '^\\+[1-9][0-9]{1,14}$'"

  def change
    add_column :residents, :phone, :string
    add_column :admin_users, :phone, :string

    # safety_assured: strong_migrations wants new CHECKs added unvalidated to
    # avoid a long lock on a big table. Both tables have under a hundred rows,
    # so validation is instant.
    safety_assured do
      add_check_constraint :residents, E164, name: 'residents_phone_e164'
      add_check_constraint :admin_users, E164, name: 'admin_users_phone_e164'
    end
  end
end

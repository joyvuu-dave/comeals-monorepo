# frozen_string_literal: true

# Since 2026-10-23 a password reset stores only the digest of the mailed
# token (reset_password_token_digest, PasswordReset), and the deploy of
# 2026-10-24 (v619) emptied this column. It stayed one release so an undo
# to the code before could still read it. v619 and three later releases
# are deployed, so the column and its index go.
class DropResidentsResetPasswordToken < ActiveRecord::Migration[8.1]
  def change
    # strong_migrations: Resident lists the column in ignored_columns in the
    # release running when this migration runs, so it never selects it.
    safety_assured do
      remove_index :residents, :reset_password_token, unique: true, name: 'index_residents_on_reset_password_token'
      remove_column :residents, :reset_password_token, :string
    end
  end
end

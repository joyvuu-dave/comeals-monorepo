# frozen_string_literal: true

# A reset token was stored exactly as it is mailed, in
# residents.reset_password_token, so anyone who could read the table could
# set that resident's password. From this release the table keeps only the
# SHA-256 digest of the token, in this new column, and the token itself is
# only in the email (PasswordReset).
#
# The old column stays for one release, ignored by Resident, so an undo to
# the release before this one still finds the column it reads and writes.
# 20261023130100 empties it.
#
# The CHECK says what the column may hold: 64 lowercase hex digits, the
# form Digest::SHA256.hexdigest writes. A token stored as it is mailed is
# never in that form (urlsafe base64, 43 characters), so a write that
# stored one by mistake fails instead of saving it.
class AddResidentsResetPasswordTokenDigest < ActiveRecord::Migration[8.1]
  def change
    add_column :residents, :reset_password_token_digest, :string

    # safety_assured: strong_migrations wants the index built concurrently
    # and the CHECK added without validation and then validated, so neither
    # blocks writes for long. residents has about a hundred rows and the
    # column was just added empty, so both take milliseconds.
    safety_assured do
      add_index :residents, :reset_password_token_digest, unique: true
      add_check_constraint :residents, "reset_password_token_digest ~ '^[0-9a-f]{64}$'",
                           name: 'residents_reset_password_token_digest_is_sha256'
    end
  end
end

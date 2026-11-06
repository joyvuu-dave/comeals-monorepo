# frozen_string_literal: true

# A resident can change their own email (ADR 0014). The new address is
# not used until the resident opens a one-use link sent to it, so a typo
# cannot lock them out. Until then it waits here:
#
#   pending_email               the address asked for
#   email_change_token_digest   SHA-256 of the link's token (EmailChange)
#   email_change_sent_at        when the link was sent; it works 24 hours
#
# The three are all set or all empty. The previous release's code never
# reads or writes them, so it runs beside this migration.
class AddResidentsEmailChange < ActiveRecord::Migration[8.1]
  def change
    add_column :residents, :pending_email, :string
    add_column :residents, :email_change_token_digest, :string
    add_column :residents, :email_change_sent_at, :datetime

    # safety_assured: strong_migrations wants a constraint added unvalidated
    # and validated in a second migration, and an index built concurrently,
    # to avoid a long lock on a big table. residents has under a hundred
    # rows, and every new column is empty, so both are instant and the
    # constraints refuse no row.
    safety_assured do
      add_check_constraint :residents,
                           '(pending_email IS NULL) = (email_change_token_digest IS NULL) AND ' \
                           '(pending_email IS NULL) = (email_change_sent_at IS NULL)',
                           name: 'residents_email_change_all_or_none'
      add_check_constraint :residents, "email_change_token_digest ~ '^[0-9a-f]{64}$'",
                           name: 'residents_email_change_token_digest_is_sha256'
      add_check_constraint :residents, "pending_email IS NULL OR lower(pending_email) NOT LIKE '%.invalid'",
                           name: 'residents_pending_email_not_invalid_domain'
      add_index :residents, :email_change_token_digest, unique: true
    end
  end
end

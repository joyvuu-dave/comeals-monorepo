# frozen_string_literal: true

# Per-resident revocation marker for JWT sessions. A JWT's `iat` (issued-at)
# claim must be >= this value for the token to be accepted. Bumping it to
# `now` invalidates every outstanding JWT for the user — used by the
# password-change callback and by any future "log out all my sessions"
# control surface.
#
# Existing residents get backfilled with their `created_at` so any JWTs
# we issue to them after deploy are valid by default.
class AddKeysValidSinceToResidents < ActiveRecord::Migration[8.1]
  def change
    add_column :residents, :keys_valid_since, :datetime,
               null: false, default: -> { 'CURRENT_TIMESTAMP' }
    up_only do
      execute 'UPDATE residents SET keys_valid_since = created_at'
    end
  end
end

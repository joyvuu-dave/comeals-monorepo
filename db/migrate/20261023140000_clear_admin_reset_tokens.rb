# frozen_string_literal: true

# Empties admin_users.reset_password_token and reset_password_sent_at on
# every row. Before this release the admin reset email carried the token
# in the link's query, and Heroku's router logs every request line with
# its query, so a token whose link was opened may be in that log. From
# this release the link carries it after the #, which is never sent
# (AdminUsers::PasswordsController). Clearing the tokens makes every link
# mailed before the deploy stop working at once, instead of up to a day
# later (a token lives 24 hours, config/initializers/devise.rb).
#
# An admin who was in the middle of a reset asks for a new link. The page
# for an old link already says to.
#
# It tries again on a conflict, like the other data migrations. down does
# nothing: the tokens cannot come back, and nothing needs them, since an
# admin can always ask for a new link.
class ClearAdminResetTokens < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ATTEMPTS = 5

  def up
    count = with_retry { connection.transaction { clear } }
    say "Cleared the reset token of #{count} admin(s). They can ask for a new link."
  end

  def down; end

  private

  # Returns how many rows it changed.
  def clear
    connection.update(<<~SQL.squish)
      UPDATE admin_users SET reset_password_token = NULL, reset_password_sent_at = NULL
      WHERE reset_password_token IS NOT NULL OR reset_password_sent_at IS NOT NULL
    SQL
  end

  def with_retry
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      raise if attempt >= ATTEMPTS || connection.transaction_open?

      say "PostgreSQL refused this for a conflict with another write. Trying again (#{attempt + 1} of #{ATTEMPTS}).",
          true
      sleep(0.1 * (2**attempt))
      retry
    end
  end
end

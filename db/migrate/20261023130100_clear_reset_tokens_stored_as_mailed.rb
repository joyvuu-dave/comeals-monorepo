# frozen_string_literal: true

# Empties residents.reset_password_token and reset_password_sent_at on
# every row. From this release a reset token is stored only as a digest
# (20261023130000, PasswordReset), and the code no longer reads the old
# column. A token still in it is a live secret in plain text that nothing
# will ever use, so it goes.
#
# A link mailed before this deploy then stops working. That is at most a
# day of links (a token lives 24 hours), and the reset page says to ask
# for a new one. Turning each old token into a digest instead would keep
# those links working, but they also carry the token in the address, which
# is what the same release takes out of the logs.
#
# reset_password_sent_at goes too, because it describes the token that is
# gone. The new code reads it only together with the digest.
#
# It tries again on a conflict, like 20261013120400. down does nothing:
# the tokens cannot come back, and nothing needs them, since a resident
# can always ask for a new link.
class ClearResetTokensStoredAsMailed < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ATTEMPTS = 5

  def up
    count = with_retry { connection.transaction { clear } }
    say "Cleared #{count} reset token(s) stored as they were mailed. Those residents can ask for a new link."
  end

  def down; end

  private

  # Returns how many rows it changed.
  def clear
    connection.update(<<~SQL.squish)
      UPDATE residents SET reset_password_token = NULL, reset_password_sent_at = NULL
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

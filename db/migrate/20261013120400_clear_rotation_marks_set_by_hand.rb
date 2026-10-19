# frozen_string_literal: true

# Takes the "residents notified" marks off the rotations that have not
# started yet and that nobody was mailed about. One of the history fixes
# the owner decided on 2026-10-12, run during the deploy so no person has
# to do it by hand.
#
# On 2026-07-11 every rotation that existed then was marked by hand as
# notified (residents_notified true, new_rotation_notified_at set; issue
# #39), although broadcast email had sent nothing since 2023. For the
# rotations that start after that day, the marks say people were told
# when nobody was. If broadcast email is turned on, residents:notify
# skips a rotation marked notified, so nobody would be asked to sign up
# to cook for it. The owner chose (2026-10-12) to take the marks off
# those rotations and leave the past ones as they are.
#
# The rule: a rotation marked residents notified, whose first meal is
# after today in the community's time zone, and with no row in
# mail_deliveries about it (that table records each mail actually sent).
# Both marks come off. A rotation with only new_rotation_notified_at set
# is left alone: the app sets that one on purpose when a rotation is made
# without email (Rotation#suppress_notification_if_no_email). In the
# production copy of 2026-10-13 a few rotations match. A deploy after the
# first meal of one of them leaves that one alone.
# rotations:notify_new only announces rotations made in the last 7 days,
# so clearing new_rotation_notified_at sends no announcement for these;
# the column then says what happened: nobody was told.
#
# This moves no money, and rotations have no history rows, so it prints
# each rotation it changed for the release log. None matching is not an
# error. It tries again on a conflict, like 20261010130000. down refuses:
# the release log says which rotations to mark again.
class ClearRotationMarksSetByHand < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ATTEMPTS = 5

  def up
    ids = with_retry { connection.transaction { clear } }
    return say('No rotation that has not started is marked notified: nothing to change.') if ids.empty?

    say "Took the notified marks off rotation(s) #{ids.map(&:to_i).sort.join(', ')}, which start after today " \
        'and nobody was mailed about.'
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Migration 20261013120400 took the notified marks off rotations that had not started. Rotations have no ' \
          'history rows; the release log of the deploy that ran it names each one.'
  end

  private

  # Returns the ids of the rotations it changed.
  def clear
    connection.select_values(<<~SQL.squish)
      UPDATE rotations SET residents_notified = false, new_rotation_notified_at = NULL,
                           updated_at = #{connection.quote(Time.current.utc)}
      WHERE rotations.residents_notified
        AND (SELECT MIN(meals.date) FROM meals WHERE meals.rotation_id = rotations.id)
            > (SELECT (now() AT TIME ZONE communities.timezone)::date FROM communities
               WHERE communities.id = rotations.community_id)
        AND NOT EXISTS (SELECT 1 FROM mail_deliveries
                        WHERE mail_deliveries.about_type = 'Rotation' AND mail_deliveries.about_id = rotations.id)
      RETURNING rotations.id
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

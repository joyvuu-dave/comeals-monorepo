# frozen_string_literal: true

# Marks cancelled every dinner before October 2026 that people signed up
# for and nobody cooked, and that is not settled. One of the history fixes
# the owner decided on 2026-10-12 (ADR 0011 rule 11), run during the
# deploy so no person has to do it by hand.
#
# A settlement never takes in a dinner with no cook, so these dinners
# could never settle, and every settlement preview would list them as
# waiting. The owner chose to mark them cancelled, not delete them: the
# sign-ups stay as the record of who meant to come, and nobody is charged.
# The next settlement then takes them in with every line at $0. On a copy
# of production from 2026-10-13 there are 27, from 2024-07 to 2026-09,
# none with a guest.
#
# The dinners are found by that rule, not by date, and locked in id
# order, the order every meal write uses. Cancelling one moves no money,
# so the count is not checked: the release log lists each dinner. A
# dinner that has a cook by then, or is settled or cancelled already,
# does not match the rule and is left as it is.
#
# Plain SQL, like migration 20261013120300 and for the same reasons. Each
# change gets the audit row a save would write ({"cancelled_at": [null,
# <time>]}), with no person and no username and this migration in the
# comment, so the meal history says "Automatic fix" and "Dinner
# cancelled". updated_at moves on the meals, so the calendar's cache
# version moves and the calendar shows them cancelled.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down restores exactly the dinners it cancelled, unless
# one changed since.
class CancelOldDinnersNobodyCooked < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261015120000).'
  COMMENT = "#{BY} Marked this dinner cancelled: people signed up, nobody cooked, and it did not happen.".freeze
  BEFORE = Date.new(2026, 10, 1)
  ATTEMPTS = 5

  # One audit row this migration wrote, read back by down.
  Cancelled = Struct.new(:audit_id, :meal_id, :date, :at)

  def up
    with_retry { connection.transaction { cancel } }.each { |line| say line }
  end

  def down
    with_retry { connection.transaction { restore } }.each { |line| say line }
  end

  private

  # Returns the lines to print.
  def cancel
    return ['This migration cancelled the dinners already: nothing to cancel.'] if done?

    rows = connection.select_rows(<<~SQL.squish)
      SELECT meals.id, meals.date FROM meals
      WHERE meals.reconciliation_id IS NULL AND meals.cancelled_at IS NULL
        AND meals.date < #{connection.quote(BEFORE)}
        AND NOT EXISTS (SELECT 1 FROM bills WHERE bills.meal_id = meals.id)
        AND (EXISTS (SELECT 1 FROM meal_residents WHERE meal_residents.meal_id = meals.id)
             OR EXISTS (SELECT 1 FROM guests WHERE guests.meal_id = meals.id))
      ORDER BY meals.id
      FOR UPDATE
    SQL
    return ["No dinner before #{BEFORE} has sign-ups and no cook: nothing to cancel."] if rows.empty?

    cancel_meals(rows.map { |id, _| Integer(id) }, Time.current.utc)
    rows.sort_by { |_, date| date.to_date }.map { |_, date| "#{date.to_date}  cancelled" } +
      ["Cancelled #{rows.size} dinner(s)."]
  end

  def done?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM audits WHERE auditable_type = 'Meal' AND comment = #{connection.quote(COMMENT)}
    SQL
  end

  def cancel_meals(ids, now)
    changes = { 'cancelled_at' => [nil, now] }.to_json
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, action, audited_changes, version, comment, username,
                          request_uuid, created_at)
      SELECT 'Meal', meals.id, 'update', #{connection.quote(changes)}::jsonb,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'Meal' AND audits.auditable_id = meals.id), 0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)}, #{connection.quote(now)}
      FROM meals WHERE meals.id IN (#{ids.join(', ')})
      ORDER BY meals.id
    SQL
    connection.execute(<<~SQL.squish)
      UPDATE meals SET cancelled_at = #{connection.quote(now)}, updated_at = #{connection.quote(now)}
      WHERE id IN (#{ids.join(', ')})
    SQL
  end

  # Returns the lines to print.
  def restore
    rows = connection.select_rows(<<~SQL.squish).map { |row| Cancelled.new(*row) }
      SELECT audits.id, audits.auditable_id, meals.date, audits.created_at FROM audits
      JOIN meals ON meals.id = audits.auditable_id
      WHERE audits.auditable_type = 'Meal' AND audits.comment = #{connection.quote(COMMENT)}
      ORDER BY audits.auditable_id
    SQL
    return ['This migration cancelled no dinner: nothing to restore.'] if rows.empty?

    ids = rows.map { |row| Integer(row.meal_id) }
    connection.execute("SELECT id FROM meals WHERE id IN (#{ids.join(', ')}) ORDER BY id FOR UPDATE")
    rows.each { |row| unchanged!(row) }
    now = connection.quote(Time.current.utc)
    connection.execute("UPDATE meals SET cancelled_at = NULL, updated_at = #{now} WHERE id IN (#{ids.join(', ')})")
    connection.execute("DELETE FROM audits WHERE id IN (#{rows.map { |row| Integer(row.audit_id) }.join(', ')})")
    ["Restored #{rows.size} dinner(s)."]
  end

  # Restoring a dinner that was restored, cancelled again by a person, or
  # settled since would undo that.
  def unchanged!(row)
    meal_id = Integer(row.meal_id)
    same = connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM meals
      WHERE meals.id = #{meal_id} AND meals.reconciliation_id IS NULL
        AND meals.cancelled_at = #{connection.quote(row.at)}
        AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'Meal'
                        AND later.auditable_id = #{meal_id} AND later.id > #{Integer(row.audit_id)})
    SQL
    return if same

    raise "The dinner of #{row.date.to_date} changed, or was settled, after migration 20261015120000, so " \
          'restoring it would undo that. Nothing was changed.'
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

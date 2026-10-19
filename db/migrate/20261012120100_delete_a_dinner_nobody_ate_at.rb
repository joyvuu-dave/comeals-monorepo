# frozen_string_literal: true

# Deletes one meal that nobody cooked and nobody ate at, and its sign-ups.
# One of the history fixes the owner decided on 2026-10-12, run during the
# deploy so no person has to do it by hand.
#
# A few people signed up for a Monday dinner, and nobody cooked. The owner
# says nobody ate. A settlement never claims a meal with no cook, so the
# meal charges nobody and can never settle, and every settlement preview
# would list it as waiting. Nothing about money changes: the sign-ups were
# never charged.
#
# The meal is found by its date (DATE), and checked under its row lock:
# not settled, no cook, no guest, and exactly SIGN_UPS sign-ups. This
# moves no money, so a meal that does not fit is left as it is, the
# release log says why, and the deploy goes on. With no meal that day (any
# database but production, or after this ran) there is nothing to do.
#
# Plain SQL, like migration 20261010130000, for the reasons given there.
# A save through the models would refuse nothing here, but would push a
# live update from the release. The audit rows a delete through the models
# writes are written here too, with no person and no username and this
# migration in the comment: one for each sign-up and one for the meal,
# each with what the row held. A row deleted from meals moves the row count
# the calendar's cache version reads (Community#calendar_cache_version),
# so the next calendar read builds the month again.
#
# down refuses. What the rows held is in the audit rows, if they are ever
# wanted back.
class DeleteADinnerNobodyAteAt < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261012120100).'
  COMMENT = "#{BY} Deleted the meal of 2026-04-06: two people signed up, nobody cooked, and nobody ate.".freeze
  DATE = Date.new(2026, 4, 6)
  SIGN_UPS = 2
  ATTEMPTS = 5

  def up
    say(with_retry { connection.transaction { delete_meal } })
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Migration 20261012120100 deleted the meal of 2026-04-06 and its sign-ups. What they held is in the ' \
          "audit rows whose comment starts with #{BY.inspect}."
  end

  private

  # Returns what to print.
  def delete_meal
    meal = connection.select_one(<<~SQL.squish)
      SELECT id, reconciliation_id, rotation_id FROM meals WHERE date = #{connection.quote(DATE)} FOR UPDATE
    SQL
    return "No meal on #{DATE}: nothing to delete." if meal.nil?

    why = why_not(meal)
    return "Left the meal of #{DATE} as it is: #{why}." unless why.nil?

    write_delete(Integer(meal['id']))
    "Deleted the meal of #{DATE} and its #{SIGN_UPS} sign-up(s)."
  end

  # Why the meal does not fit, or nil when it does.
  def why_not(meal)
    id = Integer(meal['id'])
    return 'it is settled' unless meal['reconciliation_id'].nil?
    return 'a cook is on it' if count('bills', id).positive?
    return 'a guest is on it' if count('guests', id).positive?

    sign_ups = count('meal_residents', id)
    return "it has #{sign_ups} sign-up(s), not #{SIGN_UPS}" unless sign_ups == SIGN_UPS
    return 'it is the only meal of its rotation' if count_rotation(meal['rotation_id']) == 1

    nil
  end

  def count(table, meal_id)
    connection.select_value("SELECT COUNT(*) FROM #{table} WHERE meal_id = #{meal_id}").to_i
  end

  def count_rotation(rotation_id)
    connection.select_value("SELECT COUNT(*) FROM meals WHERE rotation_id = #{Integer(rotation_id)}").to_i
  end

  def write_delete(meal_id)
    @now = connection.quote(Time.current.utc)
    @request = connection.quote(SecureRandom.uuid)
    write_rows('MealResident', 'meal_residents', "meal_residents.meal_id = #{meal_id}", "'Meal', #{meal_id}")
    write_rows('Meal', 'meals', "meals.id = #{meal_id}", 'NULL, NULL')
    connection.execute("DELETE FROM meal_residents WHERE meal_id = #{meal_id}")
    connection.execute("DELETE FROM meals WHERE id = #{meal_id}")
  end

  # One delete row per row of the table that matches: what it held, the
  # way audited writes it (every column but id and the two times), as the
  # next version of that record.
  def write_rows(type, table, where, associated)
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT #{connection.quote(type)}, #{table}.id, #{associated}, 'destroy',
             to_jsonb(#{table}.*) - 'id' - 'created_at' - 'updated_at',
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = #{connection.quote(type)} AND audits.auditable_id = #{table}.id),
                      0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{@request}, #{@now}
      FROM #{table} WHERE #{where}
      ORDER BY #{table}.id
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

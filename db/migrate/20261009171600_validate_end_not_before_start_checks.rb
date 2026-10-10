# frozen_string_literal: true

# An event or a common house booking must not end before it starts
# (#149). Step 2 of 2: check the rows already in both tables against the
# CHECKs from step 1.
#
# The production copies of 2026-09 (comeals_prodcheck, comeals_replay_old
# and comeals_replay_new) have no such row, among 883 bookings and 972
# events. Nothing in the app makes one: the models refuse it. If one
# appears before this runs (only a write that skips the model can make
# one), the migration stops and lists each one
# (refuse_rows_that_end_before_they_start), so the release fails and the
# old release keeps serving. Step 1's CHECKs are already committed by
# then, and they refuse only what the old release's models refuse too.
#
# Rollback to v613 (2146821) as code only is safe: v613's models refuse
# an end before the start as well.
class ValidateEndNotBeforeStartChecks < ActiveRecord::Migration[8.1]
  CHECKS = {
    common_house_reservations: ['common_house_reservations_end_not_before_start', 'end_date >= start_date'],
    events: ['events_end_not_before_start', 'allday OR end_date IS NULL OR end_date >= start_date']
  }.freeze

  def up
    refuse_rows_that_end_before_they_start
    CHECKS.each { |table, (name, _)| validate_check_constraint table, name: name }
  end

  # Back to the state after step 1: PostgreSQL cannot mark a CHECK as not
  # validated again, so each one is dropped and added back NOT VALID.
  def down
    CHECKS.each do |table, (name, expression)|
      remove_check_constraint table, name: name
      add_check_constraint table, expression, name: name, validate: false
    end
  end

  private

  # The validation would fail on such a row anyway, but with a message
  # about a constraint. This one names each row and its times, in the
  # community's zone as admin shows them, so the person deploying knows
  # which ones to fix.
  def refuse_rows_that_end_before_they_start
    rows = select_rows(<<~SQL.squish)
      WITH zone AS (SELECT timezone FROM communities)
      SELECT kind, id,
             to_char(start_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI'),
             to_char(end_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI')
      FROM (
        SELECT 1 AS place, 'common house booking' AS kind, id, start_date, end_date
        FROM common_house_reservations WHERE end_date < start_date
        UNION ALL
        SELECT 2, 'event', id, start_date, end_date
        FROM events WHERE NOT allday AND end_date < start_date
      ) AS reversed, zone
      ORDER BY place, start_date, id
    SQL
    return if rows.empty?

    list = rows.map { |kind, id, start, finish| "#{kind} #{id} (#{start} to #{finish})" }
    zone = select_value('SELECT timezone FROM communities')
    raise "#{rows.size} row(s) end before they start: #{list.join(', ')}. Times are in #{zone}. " \
          'Fix each one, then run this migration again.'
  end
end

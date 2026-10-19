# frozen_string_literal: true

# Two common house bookings must not hold the same time (#149). Before
# this only the model checked it (CommonHouseReservation#period_is_free),
# so a write that skips the model could store an overlap, and so could
# two bookings saved at the same moment: each checks before the other is
# written.
#
# Each booking is the range [start, end): one that ends as another
# starts does not overlap it. A booking that ends when it starts is an
# empty range, which overlaps nothing. A midnight notice is one, and so
# are the old rows from before #141. period_is_free gives the same
# answers (spec/db/common_house_reservations_no_overlap_spec.rb).
#
# tsrange refuses a range that ends before it starts, so this runs after
# 20261009171600 has proved that no booking does.
#
# The production copies of 2026-09 (comeals_prodcheck, comeals_replay_old
# and comeals_replay_new) have no overlapping pair among 883 bookings. If
# one appears before this runs (only a write that skips the model can
# make one), the migration stops and lists each pair
# (refuse_overlapping_bookings), so the release fails and the old release
# keeps serving.
#
# Rollback to v613 (2146821) as code only: v613's model refuses an
# overlap too, so it never writes one. Two of its requests that race for
# one time get a 500 instead of a 400 for the second, because v613 does
# not turn the database's refusal into words.
class AddCommonHouseReservationsNoOverlap < ActiveRecord::Migration[8.1]
  def up
    refuse_overlapping_bookings
    # safety_assured: strong_migrations warns that adding an exclusion
    # constraint blocks reads and writes while every row is checked. The
    # table has about 900 rows, so the check takes a few milliseconds.
    safety_assured do
      add_exclusion_constraint :common_house_reservations, "tsrange(start_date, end_date, '[)') WITH &&",
                               using: :gist, name: 'common_house_reservations_no_overlap'
    end
  end

  def down
    remove_exclusion_constraint :common_house_reservations, name: 'common_house_reservations_no_overlap'
  end

  private

  # The constraint would fail on such a pair anyway, but with a message
  # about a constraint. This one names each pair and its times, in the
  # community's zone as admin shows them, so the person deploying knows
  # which bookings to move.
  #
  # Only the bookings in a pair are read in the zone. The model can save
  # a booking in the first hours PostgreSQL can store (StorableTime,
  # #102), and in a zone west of UTC that is a local time PostgreSQL
  # cannot store, so reading it fails the statement.
  def refuse_overlapping_bookings
    rows = select_rows(<<~SQL.squish)
      WITH zone AS (SELECT timezone FROM communities),
      timed AS (SELECT id, start_date, end_date FROM common_house_reservations WHERE start_date < end_date)
      SELECT #{words('a')}, #{words('b')}
      FROM timed a
      JOIN timed b ON a.id < b.id AND a.start_date < b.end_date AND b.start_date < a.end_date
      CROSS JOIN zone
      ORDER BY a.start_date, a.id, b.id
    SQL
    return if rows.empty?

    list = rows.map { |first, second| "#{first} and #{second}" }
    zone = select_value('SELECT timezone FROM communities')
    raise "#{rows.size} pair(s) of common house bookings overlap: #{list.join(', ')}. Times are in #{zone}. " \
          'Move or delete one booking of each pair, then run this migration again.'
  end

  # A booking's id and times as SQL, for example "12 (2026-01-05 10:00
  # to 2026-01-05 12:00)".
  def words(booking)
    "#{booking}.id || ' (' " \
      "|| to_char(#{booking}.start_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI') " \
      "|| ' to ' " \
      "|| to_char(#{booking}.end_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI') " \
      "|| ')'"
  end
end

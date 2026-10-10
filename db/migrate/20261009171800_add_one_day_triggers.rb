# frozen_string_literal: true

# An event or a common house booking must start and end on the same day
# in the community's zone (#154). The models refuse an end on a later day
# (starts_and_ends_on_one_day), and these two triggers make PostgreSQL
# refuse it too. Without them a write that skips the model could store
# one: update_columns, update_all, insert_all, psql, or two copies of one
# row saved one after the other. For example, one copy moves a booking to
# the day before, and the other, loaded earlier, moves only its end. Each
# copy is one day as it sees it, and Rails writes only the columns that
# changed, so the row would run over two days.
#
# A trigger, not a CHECK: the day depends on the community's zone, and a
# CHECK cannot read another table. Each trigger runs only when a write
# sets the times (for an event, also all day). So when an admin changes
# the community's zone and a row now ends on a later day, a write of
# other columns still goes through; the model still refuses every save
# of it until its times are fixed. An all-day event's end does not count,
# and a timed event with no end is refused by the model
# (end_date_or_allday). The refusal is a check_violation that names
# events_one_day or common_house_reservations_one_day, and the models
# answer it in their own words (ConstraintMessages).
#
# A trigger checks only new writes, so this migration also checks the
# rows already there (refuse_rows_on_two_days), the way a CHECK added NOT
# VALID is validated. The production copies of 2026-09 (comeals_prodcheck,
# comeals_replay_old and comeals_replay_new) have none among 883 bookings
# and 972 events. If one appears before this runs, the migration stops and
# lists each one, so the release fails and the old release keeps serving.
# The triggers are made first: CREATE TRIGGER locks each table against
# writes until this migration commits, so no row can be written between
# the check and the commit.
#
# Rollback to v613 (2146821) as code only: v613's admin forms can save an
# event or a booking that ends on a later day. The trigger refuses it,
# and v613 shows an error page instead of words.
class AddOneDayTriggers < ActiveRecord::Migration[8.1]
  def up
    # Two functions and two triggers. strong_migrations cannot read inside
    # execute, so it asks. A CREATE TRIGGER locks the table only until the
    # migration commits, and the check below reads about 1,900 rows.
    safety_assured do
      create_local_day
      create_refuse_two_days
      create_triggers
    end
    refuse_rows_on_two_days
  end

  def down
    safety_assured do
      execute 'DROP TRIGGER events_one_day ON events;'
      execute 'DROP TRIGGER common_house_reservations_one_day ON common_house_reservations;'
      execute 'DROP FUNCTION comeals_refuse_two_days();'
      execute 'DROP FUNCTION comeals_local_day(timestamp, text);'
    end
  end

  private

  # The day a stored time falls on in a zone, the way Community#date_of
  # reads it. The stored times are UTC, so each is read in UTC and then
  # in the zone.
  #
  # NULL for a time less than a day from the first or last one PostgreSQL
  # can store (midnight UTC on November 24, 4714 BC, and the end of
  # 294276). In a zone west or east of UTC, such a time can be a local
  # time PostgreSQL cannot store, and reading it fails the statement: Los
  # Angeles kept local mean time then, 7:52:58 behind UTC. The model can
  # save such a time (StorableTime, #102) and checks its day itself. No
  # zone is a whole day from UTC, so every other time can be read.
  def create_local_day
    execute <<~SQL.squish
      CREATE FUNCTION comeals_local_day(stored timestamp, zone text) RETURNS date
      LANGUAGE sql STABLE
      AS $$
        SELECT CASE
          WHEN stored < '4714-11-25 00:00:00 BC' OR stored >= '294276-12-31 00:00:00' THEN NULL
          ELSE (stored AT TIME ZONE 'UTC' AT TIME ZONE zone)::date
        END
      $$;
    SQL
  end

  # A day that is NULL is not compared (comeals_local_day). The
  # trigger's name is the rule's name, so ConstraintMessages finds the
  # words for it.
  def create_refuse_two_days
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_refuse_two_days() RETURNS trigger AS $$
      DECLARE
        zone text;
        start_day date;
        end_day date;
      BEGIN
        SELECT timezone INTO zone FROM communities;
        start_day := comeals_local_day(NEW.start_date, zone);
        end_day := comeals_local_day(NEW.end_date, zone);

        IF start_day <> end_day THEN
          RAISE EXCEPTION '% on % refused: row % starts on % and ends on % in %. '
            'It must start and end on the same day.',
            TG_OP, TG_TABLE_NAME, NEW.id, start_day, end_day, zone
            USING ERRCODE = 'check_violation', CONSTRAINT = TG_NAME;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  # The events trigger skips an all-day event and an event with no end
  # in its WHEN, where the columns are named once, at CREATE TRIGGER.
  def create_triggers
    execute <<~SQL.squish
      CREATE TRIGGER common_house_reservations_one_day
      BEFORE INSERT OR UPDATE OF start_date, end_date ON common_house_reservations
      FOR EACH ROW EXECUTE FUNCTION comeals_refuse_two_days();
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER events_one_day
      BEFORE INSERT OR UPDATE OF start_date, end_date, allday ON events
      FOR EACH ROW WHEN (NOT NEW.allday AND NEW.end_date IS NOT NULL)
      EXECUTE FUNCTION comeals_refuse_two_days();
    SQL
  end

  # Names each row and its times, in the community's zone as admin shows
  # them, so the person deploying knows which ones to fix.
  def refuse_rows_on_two_days
    rows = select_rows(<<~SQL.squish)
      WITH zone AS (SELECT timezone FROM communities)
      SELECT kind, id,
             to_char(start_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI'),
             to_char(end_date AT TIME ZONE 'UTC' AT TIME ZONE zone.timezone, 'YYYY-MM-DD HH24:MI')
      FROM (
        SELECT 1 AS place, 'common house booking' AS kind, id, start_date, end_date
        FROM common_house_reservations
        UNION ALL
        SELECT 2, 'event', id, start_date, end_date
        FROM events WHERE NOT allday AND end_date IS NOT NULL
      ) AS timed, zone
      WHERE comeals_local_day(start_date, zone.timezone) <> comeals_local_day(end_date, zone.timezone)
      ORDER BY place, start_date, id
    SQL
    return if rows.empty?

    list = rows.map { |kind, id, start, finish| "#{kind} #{id} (#{start} to #{finish})" }
    zone = select_value('SELECT timezone FROM communities')
    raise "#{rows.size} row(s) start and end on different days: #{list.join(', ')}. Times are in #{zone}. " \
          'Fix each one, then run this migration again.'
  end
end

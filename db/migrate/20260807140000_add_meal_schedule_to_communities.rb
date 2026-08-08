# frozen_string_literal: true

# Make the meal schedule data instead of code (#53).
#
# The old schedule was three hard-coded methods on Community: meals every
# Sunday and Thursday, plus Monday one week and Tuesday the next. "Alternating
# Monday and Tuesday" is not a special rule — it is a two-week repeating
# schedule. Week A: Sun, Mon, Thu. Week B: Sun, Tue, Thu. So the general model
# is: a schedule is a cycle of 1 to 6 weeks, and each week is a set of days
# (0 = Sunday .. 6 = Saturday). A week may be empty — that is how a community
# skips weeks — but the cycle as a whole must contain at least one day, or
# the meal generator would walk forward forever finding nothing.
#
# schedule_anchor_date names which calendar week is week 1 of the cycle. It is
# always a Sunday (weeks are Sunday-start everywhere in this app). With an
# anchor, the cycle phase for any date is plain arithmetic; the old code had
# to derive the phase by querying past meals and tracking ISO week numbers.
#
# The backfill picks the anchor from the last existing Monday-or-Tuesday meal
# so the first rotation generated after this deploys continues the current
# alternation exactly. The old code grouped by ISO (Monday-start) weeks and
# this model groups by Sunday-start weeks, but Monday and Tuesday fall in the
# same week either way, so the phase carries over without adjustment.
class AddMealScheduleToCommunities < ActiveRecord::Migration[8.1]
  def up
    add_column :communities, :schedule, :jsonb, null: false, default: [[0, 1, 4], [0, 2, 4]]
    add_column :communities, :meals_per_rotation, :integer, null: false, default: 12
    add_column :communities, :schedule_anchor_date, :date

    add_check_constraint :communities, 'meals_per_rotation BETWEEN 1 AND 100',
                         name: 'communities_meals_per_rotation_range'
    add_check_constraint :communities, 'EXTRACT(dow FROM schedule_anchor_date) = 0',
                         name: 'communities_schedule_anchor_is_sunday'

    # The shape rules live in a function because CHECK expressions cannot use
    # subqueries, and Rails validations only run on writes that go through the
    # model (CLAUDE.md: update_all, rake tasks, and psql all skip them).
    # plpgsql rather than plain SQL so a malformed value returns false step by
    # step instead of erroring inside jsonb_array_elements on a non-array.
    execute <<~SQL
      CREATE FUNCTION comeals_valid_meal_schedule(schedule jsonb) RETURNS boolean AS $$
      DECLARE
        week jsonb;
        day jsonb;
        day_count integer := 0;
      BEGIN
        IF schedule IS NULL OR jsonb_typeof(schedule) <> 'array' THEN
          RETURN false;
        END IF;
        IF jsonb_array_length(schedule) < 1 OR jsonb_array_length(schedule) > 6 THEN
          RETURN false;
        END IF;
        FOR week IN SELECT * FROM jsonb_array_elements(schedule) LOOP
          IF jsonb_typeof(week) <> 'array' THEN
            RETURN false;
          END IF;
          FOR day IN SELECT * FROM jsonb_array_elements(week) LOOP
            -- A day is a whole number 0..6. The text form of any other jsonb
            -- number ("3.5", "-1", "7") fails the pattern.
            IF jsonb_typeof(day) <> 'number' OR day::text !~ '^[0-6]$' THEN
              RETURN false;
            END IF;
            day_count := day_count + 1;
          END LOOP;
        END LOOP;
        RETURN day_count > 0;
      END;
      $$ LANGUAGE plpgsql IMMUTABLE;
    SQL

    add_check_constraint :communities, 'comeals_valid_meal_schedule(schedule)',
                         name: 'communities_schedule_shape'

    # Anchor backfill. The last Monday-or-Tuesday meal tells us the current
    # phase: a Monday meal means its week is a week-1 week ([0,1,4]); a
    # Tuesday meal means its week is a week-2 week, so week 1 was the week
    # before. With no Monday/Tuesday meal at all there is no alternation to
    # continue and either phase is defensible; the current week is week 1.
    # (That branch is dead in production, which has years of them.)
    row = select_one('SELECT max(date) AS date FROM meals WHERE extract(dow FROM date) IN (1, 2)')
    last_alt = row['date'] && Date.parse(row['date'].to_s)
    anchor =
      if last_alt.nil?
        Date.current - Date.current.wday
      else
        sunday = last_alt - last_alt.wday
        last_alt.wday == 1 ? sunday : sunday - 7
      end
    Community.reset_column_information
    Community.update_all(schedule_anchor_date: anchor)

    change_column_null :communities, :schedule_anchor_date, false
  end

  def down
    remove_check_constraint :communities, name: 'communities_schedule_shape'
    execute 'DROP FUNCTION comeals_valid_meal_schedule(jsonb);'
    remove_check_constraint :communities, name: 'communities_schedule_anchor_is_sunday'
    remove_check_constraint :communities, name: 'communities_meals_per_rotation_range'
    remove_column :communities, :schedule_anchor_date
    remove_column :communities, :meals_per_rotation
    remove_column :communities, :schedule
  end
end

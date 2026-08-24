# frozen_string_literal: true

# Dinner start times become a community setting: one "HH:MM" per weekday,
# Sunday first, default 19:00 every day. Before this they were constants
# in MealIcalFeed (18:00 Sunday, 19:00 other days), and a copy of the same
# rule wrote meals.start_time on every meal.
#
# That column goes away. Every row written since 2018-04-30 was wrong:
# Meal#set_start_time built the value with Date#to_datetime + 19.hours,
# which is 19:00 UTC, not 19:00 in the community's zone (noon Pacific).
# The 2017 backfill (20171127154541) had it right; the callback added in
# #24 did not. Nothing reads the column — the SPA never did, and the iCal
# feed builds its own times — so nobody saw the wrong hour. A per-meal copy
# of a community setting is also the kind of stored derived value this app
# avoids; if a single meal ever needs its own time, that is a new nullable
# column with its own meaning.
#
# The backfill sets Sunday to 18:00. That is what every Sunday meal since
# 2017 shows in production (dow 0 is the one weekday stored an hour
# earlier, in both the correct 2017 rows and the wrong 2018+ rows), what
# the 2017 migration wrote, and what MealIcalFeed hard-coded.
class MoveDinnerStartTimesToCommunities < ActiveRecord::Migration[8.1]
  ALL_AT_SEVEN = Array.new(7, '19:00').freeze

  # safety_assured: strong_migrations cannot read the execute blocks. The
  # function is new, the backfill touches one row, and the dropped column
  # has no reader (grep start_time). One dyno, one small table.
  def up
    safety_assured { unsafe_up }
  end

  def down
    safety_assured { unsafe_down }
  end

  private

  def unsafe_up
    add_column :communities, :dinner_start_times, :jsonb, null: false, default: ALL_AT_SEVEN

    # Shape rules live in a function because a CHECK cannot loop, and Rails
    # validations only run on writes that go through the model.
    execute <<~SQL
      CREATE FUNCTION comeals_valid_dinner_start_times(times jsonb) RETURNS boolean AS $$
      DECLARE
        item jsonb;
      BEGIN
        IF times IS NULL OR jsonb_typeof(times) <> 'array' OR jsonb_array_length(times) <> 7 THEN
          RETURN false;
        END IF;
        FOR item IN SELECT * FROM jsonb_array_elements(times) LOOP
          -- A 24-hour clock time, "HH:MM", zero-padded. The #>> '{}' form
          -- reads the string without its JSON quotes.
          IF jsonb_typeof(item) <> 'string' OR (item #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
            RETURN false;
          END IF;
        END LOOP;
        RETURN true;
      END;
      $$ LANGUAGE plpgsql IMMUTABLE;
    SQL
    add_check_constraint :communities, 'comeals_valid_dinner_start_times(dinner_start_times)',
                         name: 'communities_dinner_start_times_shape'

    execute <<~SQL.squish
      UPDATE communities SET dinner_start_times = jsonb_set(dinner_start_times, '{0}', '"18:00"')
    SQL

    remove_column :meals, :start_time
  end

  def unsafe_down
    add_column :meals, :start_time, :datetime
    # The old callback's value, in the community's zone (the 2017 rule).
    execute <<~SQL.squish
      UPDATE meals SET start_time =
        (meals.date + CASE WHEN EXTRACT(dow FROM meals.date) = 0 THEN time '18:00' ELSE time '19:00' END)
        AT TIME ZONE (SELECT timezone FROM communities WHERE communities.id = meals.community_id)
    SQL
    change_column_null :meals, :start_time, false

    remove_check_constraint :communities, name: 'communities_dinner_start_times_shape'
    execute 'DROP FUNCTION comeals_valid_dinner_start_times(jsonb);'
    remove_column :communities, :dinner_start_times
  end
end

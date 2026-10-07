# frozen_string_literal: true

# Every meal belongs to a rotation (#100). Step 2 of 2: check the rows
# already in meals against the CHECK from step 1, then set NOT NULL on
# meals.rotation_id. Postgres skips its own scan for the NOT NULL because
# the validated CHECK already proves it, and then the CHECK is dropped:
# NOT NULL says the same thing.
#
# Before this, the admin New Meal form saved a meal with no rotation, and
# the nightly EnsureRotationsJob then raised every night until someone
# fixed the data. Production had no meal without a rotation on
# 2026-10-07. If one appears before this runs, the migration stops and
# lists the dates (refuse_meals_without_a_rotation), so the release fails
# and the old release keeps serving. Step 1's CHECK is already committed
# by then, so until a release with the fixed admin form goes out, that
# old release's New Meal form gives a 500 (see the next paragraph).
#
# Rollback to v613 (2146821) as code only: v613's admin New Meal form
# does not send a rotation, so it would get a database error (a 500
# page) instead of saving a meal with no rotation. Nothing else in v613
# writes a meal without one: the nightly rake task makes each rotation
# with its meals (Community#create_next_rotation, nested attributes), the
# admin rotation form only moves meals into a rotation or deletes them
# (dependent: :destroy), and the API never creates a meal. db/seeds.rb,
# the test seeds and bin/lib/staging_smoke_seed.rb also make meals with
# no rotation in v613, but none of them runs in production.
#
# This is not the whole story of a rollback to v613 (#133). Another
# migration that is not deployed yet drops meals.start_time, and v613
# sets that column on every new meal. If both ship in one release, v613
# after a rollback cannot create a meal from any path.
class ValidateMealsRotationIdNullCheck < ActiveRecord::Migration[8.1]
  def up
    refuse_meals_without_a_rotation
    validate_check_constraint :meals, name: 'meals_rotation_id_null'
    change_column_null :meals, :rotation_id, false
    remove_check_constraint :meals, name: 'meals_rotation_id_null'
  end

  def down
    add_check_constraint :meals, 'rotation_id IS NOT NULL', name: 'meals_rotation_id_null', validate: false
    change_column_null :meals, :rotation_id, true
  end

  private

  # The validation would fail on such a row anyway, but with a message
  # about a constraint. This one names the meals, so the person deploying
  # knows which ones to fix.
  def refuse_meals_without_a_rotation
    dates = select_values('SELECT date FROM meals WHERE rotation_id IS NULL ORDER BY date')
    return if dates.empty?

    raise "#{dates.size} meal(s) have no rotation: #{dates.join(', ')}. " \
          'Give each one a rotation, then run this migration again.'
  end
end

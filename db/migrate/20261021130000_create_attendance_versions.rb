# frozen_string_literal: true

# A version number for each person's attendance on each meal. It goes up
# by one on every insert, update and delete of their meal_residents row.
#
# Why. A tap on the meal page sends its request at once, and the next tap
# does not wait for the answer, so two requests can reach the server in
# the other order. A request can also be held on the network after the
# page gave up on it. Each attendance write now carries the version the
# page expects, and the API refuses one built on another version (409,
# type "stale"). Comparing the state alone is not enough: an old sign-up
# that arrives after a newer sign-up and take-off finds "not signed up",
# which is the state it expects. The version is different, so it is
# refused.
#
# Why its own table. A take-off deletes the meal_residents row, so a
# number kept on that row would be lost, and would start again at the
# same value when the person signs up again.
#
# Why a trigger. Every write path must move the version: the API, admin,
# a rake task, psql. A model callback runs only for writes through the
# model.
#
# - meal_id, resident_id: one row per person and meal, made by the first
#   write of their attendance. No row means version 0. When an open meal
#   is deleted, its versions mean nothing, so they go with it. The same
#   for a resident, who can be deleted only when they have no
#   attendance.
# - version: how many writes there have been.
#
# No timestamps: only the trigger writes a row, and nothing reads a time
# from it. The audits of meal_residents say when each write was made.
#
# The table records how many writes there were, not money. Nothing reads
# a price from it (money rule 8).
class CreateAttendanceVersions < ActiveRecord::Migration[8.1]
  def up
    create_table :attendance_versions do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      # The unique index below starts with meal_id, so it serves the
      # foreign key too.
      t.references :meal, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :resident, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :version, null: false
    end
    add_index :attendance_versions, %i[meal_id resident_id], unique: true
    add_check_constraint :attendance_versions, 'version > 0', name: 'attendance_versions_version_positive'

    # strong_migrations cannot see inside execute, so it asks. The function
    # and the trigger are new; nothing uses them yet.
    safety_assured do
      execute function
      execute <<~SQL.squish
        CREATE TRIGGER meal_residents_count_attendance_version
        AFTER INSERT OR UPDATE OR DELETE ON meal_residents
        FOR EACH ROW EXECUTE FUNCTION comeals_count_attendance_version()
      SQL
    end
  end

  def down
    safety_assured do
      execute 'DROP TRIGGER meal_residents_count_attendance_version ON meal_residents'
      execute 'DROP FUNCTION comeals_count_attendance_version()'
    end
    drop_table :attendance_versions
  end

  private

  # A PL/pgSQL body keeps its line breaks, so the heredoc is not squished.
  # An update that moves a row to another person or meal counts for both.
  def function
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    <<~SQL
      CREATE FUNCTION comeals_count_attendance_version() RETURNS trigger AS $$
      BEGIN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          INSERT INTO attendance_versions (meal_id, resident_id, version)
          VALUES (OLD.meal_id, OLD.resident_id, 1)
          ON CONFLICT (meal_id, resident_id)
          DO UPDATE SET version = attendance_versions.version + 1;
        END IF;

        IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND
            (NEW.meal_id, NEW.resident_id) IS DISTINCT FROM (OLD.meal_id, OLD.resident_id)) THEN
          INSERT INTO attendance_versions (meal_id, resident_id, version)
          VALUES (NEW.meal_id, NEW.resident_id, 1)
          ON CONFLICT (meal_id, resident_id)
          DO UPDATE SET version = attendance_versions.version + 1;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end

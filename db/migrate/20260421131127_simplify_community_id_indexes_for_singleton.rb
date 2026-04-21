# frozen_string_literal: true

# Drop community_id from every index.
#
# Comeals became a single-tenant app with migrations 20260408000001 (singleton
# guard) and 20260408000002 (delete trigger). The schema still carries the
# multi-tenant-era convention of prefixing every composite index with
# community_id — but in a singleton world that column has exactly one value,
# which means:
#
#   1. Standalone indexes on community_id never help any query (selectivity = 0).
#   2. Composite indexes like (community_id, start_date) waste 8 bytes per
#      entry on a constant column; a single-column (start_date) is strictly
#      smaller and equally usable.
#   3. Unique composites like (community_id, date) degenerate to "unique per
#      community = unique globally"; the single-column (date) is the honest
#      constraint.
#
# The community_id column and FK stay — they're real data. Only the indexes
# and the uniqueness shape change.
#
# Calendar query perf: events, common_house_reservations, and
# guest_room_reservations all do date-range scans. They get single-column
# start_date/date indexes here (previously unindexed on the date column).
class SimplifyCommunityIdIndexesForSingleton < ActiveRecord::Migration[8.1]
  def up
    # Calendar range-scan tables: replace standalone community_id with the
    # date column that queries actually filter on.
    remove_index :events, :community_id
    add_index :events, :start_date

    remove_index :common_house_reservations, :community_id
    add_index :common_house_reservations, :start_date

    # Unique composites collapse to single-column unique constraints.
    # Semantically identical in a singleton.
    remove_index :guest_room_reservations, %i[community_id date]
    remove_index :guest_room_reservations, :community_id
    add_index :guest_room_reservations, :date, unique: true

    remove_index :meals, %i[community_id date]
    add_index :meals, :date, unique: true

    remove_index :residents, %i[name community_id]
    remove_index :residents, :community_id
    add_index :residents, :name, unique: true

    remove_index :units, %i[community_id name]
    remove_index :units, :community_id
    add_index :units, :name, unique: true

    # Tables where community_id was only ever a standalone index.
    remove_index :admin_users, :community_id
    remove_index :bills, :community_id
    remove_index :meal_residents, :community_id
    remove_index :reconciliations, :community_id
    remove_index :rotations, :community_id
  end

  def down
    add_index :rotations, :community_id, name: :index_rotations_on_community_id
    add_index :reconciliations, :community_id, name: :index_reconciliations_on_community_id
    add_index :meal_residents, :community_id, name: :index_meal_residents_on_community_id
    add_index :bills, :community_id, name: :index_bills_on_community_id
    add_index :admin_users, :community_id, name: :index_admin_users_on_community_id

    remove_index :units, :name
    add_index :units, :community_id, name: :index_units_on_community_id
    add_index :units, %i[community_id name], unique: true, name: :index_units_on_community_id_and_name

    remove_index :residents, :name
    add_index :residents, :community_id, name: :index_residents_on_community_id
    add_index :residents, %i[name community_id], unique: true, name: :index_residents_on_name_and_community_id

    remove_index :meals, :date
    add_index :meals, %i[community_id date], unique: true, name: :index_meals_on_community_id_and_date

    remove_index :guest_room_reservations, :date
    add_index :guest_room_reservations, :community_id,
              name: :index_guest_room_reservations_on_community_id
    add_index :guest_room_reservations, %i[community_id date],
              unique: true,
              name: :index_guest_room_reservations_on_community_id_and_date

    remove_index :common_house_reservations, :start_date
    add_index :common_house_reservations, :community_id, name: :index_common_house_reservations_on_community_id

    remove_index :events, :start_date
    add_index :events, :community_id, name: :index_events_on_community_id
  end
end

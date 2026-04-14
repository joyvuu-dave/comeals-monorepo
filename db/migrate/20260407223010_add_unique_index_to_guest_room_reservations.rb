# frozen_string_literal: true

class AddUniqueIndexToGuestRoomReservations < ActiveRecord::Migration[8.1]
  def up
    # Log and remove duplicates before adding unique index. Keep the earliest
    # reservation for each (community_id, date) pair. We keep the earliest
    # (not freshest) because the first booking should win — later duplicates
    # are the ones that slipped through without the unique constraint.
    dupes = execute(<<~SQL.squish).to_a
      SELECT id, community_id, resident_id, date
      FROM guest_room_reservations
      WHERE id NOT IN (
        SELECT DISTINCT ON (community_id, date) id
        FROM guest_room_reservations
        ORDER BY community_id, date, created_at ASC
      )
    SQL

    if dupes.any?
      say "Deleting #{dupes.size} duplicate guest_room_reservations:"
      dupes.each do |row|
        say "  id=#{row['id']} community_id=#{row['community_id']} " \
            "resident_id=#{row['resident_id']} date=#{row['date']}"
      end

      execute <<~SQL.squish
        DELETE FROM guest_room_reservations
        WHERE id IN (#{dupes.pluck('id').join(', ')})
      SQL
    end

    add_index :guest_room_reservations, %i[community_id date], unique: true
  end

  def down
    remove_index :guest_room_reservations, %i[community_id date]
  end
end

# frozen_string_literal: true

class AddSingletonGuardToCommunities < ActiveRecord::Migration[8.1]
  def up
    # Keep only the community with the lowest ID and delete everything else.
    # Production has exactly one community so this is a no-op there; it only
    # cleans up dev/seed data. Deletes must respect FK ordering (children first).
    keeper_id = execute('SELECT MIN(id) FROM communities').first['min']

    if keeper_id
      doomed = "community_id != #{keeper_id}"
      # Children of meals (must go before meals)
      execute "DELETE FROM bills WHERE #{doomed}"
      execute "DELETE FROM meal_residents WHERE #{doomed}"
      execute "DELETE FROM guests WHERE meal_id IN (SELECT id FROM meals WHERE #{doomed})"
      # Top-level community children
      execute "DELETE FROM meals WHERE #{doomed}"
      execute "DELETE FROM reconciliations WHERE #{doomed}"
      execute "DELETE FROM events WHERE #{doomed}"
      execute "DELETE FROM guest_room_reservations WHERE #{doomed}"
      execute "DELETE FROM common_house_reservations WHERE #{doomed}"
      execute "DELETE FROM rotations WHERE #{doomed}"
      execute "DELETE FROM keys WHERE identity_type = 'Resident' " \
              "AND identity_id IN (SELECT id FROM residents WHERE #{doomed})"
      execute "DELETE FROM resident_balances WHERE resident_id IN (SELECT id FROM residents WHERE #{doomed})"
      execute "DELETE FROM residents WHERE #{doomed}"
      execute "DELETE FROM units WHERE #{doomed}"
      execute "DELETE FROM admin_users WHERE #{doomed}"
      execute "DELETE FROM communities WHERE id != #{keeper_id}"
    end

    add_column :communities, :singleton_guard, :integer, default: 0, null: false
    add_index :communities, :singleton_guard, unique: true
  end

  def down
    remove_index :communities, :singleton_guard
    remove_column :communities, :singleton_guard
  end
end

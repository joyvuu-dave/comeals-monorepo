# frozen_string_literal: true

# We added `last_used_at` and `device_name` earlier to back a sessions-listing
# UI ("log out this device", etc). After deciding password-change is the only
# revocation mechanism we need, this metadata is dead weight — nothing reads
# it, and it only costs schema noise and write throttling code.
class DropSessionMetadataFromKeys < ActiveRecord::Migration[8.1]
  def change
    remove_column :keys, :last_used_at, :datetime
    remove_column :keys, :device_name, :string
  end
end

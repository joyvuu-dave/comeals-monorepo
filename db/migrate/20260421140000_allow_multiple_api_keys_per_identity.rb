# frozen_string_literal: true

# Allow a resident to hold multiple simultaneous API sessions (one per device),
# and track per-session metadata so "log out this device" is meaningful.
#
# Before: UNIQUE(identity_type, identity_id) — one row per resident, token
# rotated on password change. No way to revoke a single device.
#
# After: multiple keys per identity; `last_used_at` and `device_name` let us
# render a recognizable session list for revocation.
class AllowMultipleApiKeysPerIdentity < ActiveRecord::Migration[8.1]
  def up
    remove_index :keys, name: 'index_keys_on_identity_type_and_identity_id'
    add_index :keys, %i[identity_type identity_id],
              name: 'index_keys_on_identity_type_and_identity_id'

    add_column :keys, :last_used_at, :datetime
    add_column :keys, :device_name, :string

    # Stamp pre-existing keys with `created_at` so sessions page has something to show.
    execute <<~SQL.squish
      UPDATE keys SET last_used_at = created_at WHERE last_used_at IS NULL
    SQL
  end

  def down
    # Irreversible: converting many-per-identity back to one would require
    # choosing which key survives. Refuse rather than silently destroy data.
    raise ActiveRecord::IrreversibleMigration
  end
end

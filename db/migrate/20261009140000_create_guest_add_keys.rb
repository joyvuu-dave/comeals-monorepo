# frozen_string_literal: true

# The Idempotency-Key of each guest add that was written (S2), by the same
# rules as a bills save's key (bills_save_keys, ADR 0009).
#
# A guest add whose answer is lost may have been written. The meal page
# then shows no guest, and the person taps again. The page sends the
# first tap's key with that tap, and the server writes this row in the
# same transaction as the guest, so a row exists exactly when that tap's
# guest was written. A tap whose key has a row adds nothing.
#
# The table records requests, not money. Nothing reads a price from it,
# and the guests stay the source of truth (money rule 8).
#
# - meal_id: a key belongs to one meal. When an open meal is deleted, its
#   keys mean nothing, so they go with it.
# - key: the key as the header carried it, without the quotes: 1 to 255
#   printable ASCII characters, as for a bills save.
# - resident_id and vegetarian: what the add asked for, its host and its
#   flag. The same key with another host or flag is refused with 422.
#   They are kept here, not read from the guest, because the guest can be
#   removed while the key is kept. A resident can be deleted only when
#   they have no guests (Resident's deletion guards), and then their keys
#   mean nothing and go with them.
# - guest_id: the guest the add made, so a tap sent again is answered with
#   it. When that guest is removed, the row stays, so the key still adds
#   nothing, and this becomes null.
# - created_at: a key is kept 7 days. GuestAddKey.delete_expired deletes
#   the older ones every hour (config/recurring.yml), by this index.
#
# No updated_at: the app never changes a row. Only PostgreSQL does, when
# it sets guest_id to null.
class CreateGuestAddKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :guest_add_keys do |t|
      # The unique index below starts with meal_id, so it serves the
      # foreign key too.
      t.references :meal, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.text :key, null: false
      t.references :resident, null: false, foreign_key: { on_delete: :cascade }
      # No default: every row is written with the add's own flag, and a
      # default would hide a row written without one.
      t.boolean :vegetarian, null: false # rubocop:disable Rails/ThreeStateBooleanColumn
      t.references :guest, null: true, foreign_key: { on_delete: :nullify }
      t.datetime :created_at, null: false
    end

    add_index :guest_add_keys, %i[meal_id key], unique: true
    add_index :guest_add_keys, :created_at

    add_check_constraint :guest_add_keys, "key ~ '^[ -~]{1,255}$'", name: 'guest_add_keys_key_printable'
  end
end

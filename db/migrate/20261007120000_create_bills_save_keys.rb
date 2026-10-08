# frozen_string_literal: true

# The Idempotency-Key of each bills save that was written (decision 6 of
# #135, docs/adr/0009-bills-saves-send-edits.md).
#
# The page sends one new key with each bills save, and the same key when
# it sends that save again after no answer. The server writes the key's
# row in the same transaction as the bills, so a row exists exactly when
# that save's bills were written. A resend whose key has a row writes
# nothing.
#
# The table records requests, not money. Nothing reads an amount from it,
# and the bills stay the source of truth (money rule 8).
#
# - meal_id: a key belongs to one meal. When an open meal is deleted, its
#   keys mean nothing, so they go with it.
# - key: the key as the header carried it, without the quotes. The
#   header's value is a Structured Field String (RFC 9651), which is
#   printable ASCII; the app takes 1 to 255 characters of it.
# - edits_sha256: the SHA-256, in lowercase hex, of what the save's edits
#   ask for (BillsPayload#fingerprint). A key sent again with other edits
#   is refused with 422.
# - created_at: a key is kept 7 days. BillsSaveKey.delete_expired deletes
#   the older ones every hour (config/recurring.yml), by this index.
#
# No updated_at, because a row is never changed.
class CreateBillsSaveKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :bills_save_keys do |t|
      # The unique index below starts with meal_id, so it serves the
      # foreign key too.
      t.references :meal, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.text :key, null: false
      t.text :edits_sha256, null: false
      t.datetime :created_at, null: false
    end

    add_index :bills_save_keys, %i[meal_id key], unique: true
    add_index :bills_save_keys, :created_at

    add_check_constraint :bills_save_keys, "key ~ '^[ -~]{1,255}$'", name: 'bills_save_keys_key_printable'
    add_check_constraint :bills_save_keys, "edits_sha256 ~ '^[0-9a-f]{64}$'", name: 'bills_save_keys_edits_sha256_hex'
  end
end

# frozen_string_literal: true

# The Idempotency-Key of each calendar write and each settlement that was
# saved (challenge 30, docs/adr/0015-idempotency-keys-on-calendar-writes.md).
#
# A phone that sends a write and loses the answer cannot tell whether the
# write was saved, and sends it again. bin/faults found that the second
# send saved an event twice, answered a guest room or common house booking
# with "taken", and answered a delete with 404. Now the page sends the
# same key with the second send, and the server writes this row in the
# same transaction as the write, so a row exists exactly when that write
# was saved. A send whose key has a row writes nothing and gets the
# answer stored here.
#
# - sender: who sent the write, "Resident:<id>" or "CommonHouseLogin:<id>".
#   A key belongs to one sender, so two people's keys never meet. Not a
#   foreign key, because it names one of two tables; a deleted sender's
#   keys are deleted after 7 days like the rest.
# - key: the key as the header carried it, without the quotes: 1 to 255
#   printable ASCII characters, as for a bills save.
# - request_sha256: the hash of the method, the path and the parameters,
#   so the same key with another request is refused with 422.
# - status and body: the answer, sent again for a second send. Only an
#   answer that saved something is kept (2xx). A refused write saved
#   nothing, so sending it again is safe without a key.
# - created_at: a key is kept 7 days. RequestKey.delete_expired deletes
#   the older ones every hour (config/recurring.yml), by this index.
#
# The table records requests, not money. Nothing reads an amount from it
# (money rule 8). No updated_at: a row is never changed.
class CreateRequestKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :request_keys do |t|
      t.text :sender, null: false
      t.text :key, null: false
      t.text :request_sha256, null: false
      t.integer :status, null: false, limit: 2
      t.jsonb :body, null: false
      t.datetime :created_at, null: false
    end

    add_index :request_keys, %i[sender key], unique: true
    add_index :request_keys, :created_at

    add_check_constraint :request_keys, "sender ~ '^(Resident|CommonHouseLogin):[1-9][0-9]*$'",
                         name: 'request_keys_sender_names_a_login'
    add_check_constraint :request_keys, "key ~ '^[ -~]{1,255}$'", name: 'request_keys_key_printable'
    add_check_constraint :request_keys, "request_sha256 ~ '^[0-9a-f]{64}$'", name: 'request_keys_sha256_is_hex'
    add_check_constraint :request_keys, 'status BETWEEN 200 AND 299', name: 'request_keys_status_saved_something'
  end
end

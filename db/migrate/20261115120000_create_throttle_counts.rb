# frozen_string_literal: true

# Rack::Attack's request counts (config/initializers/rack_attack.rb), one
# row per rule, address and time window: "rack::attack:<window>:<rule>:
# <address>". They were rows in solid_cache until #292. solid_cache adds
# to a count with a read and then a write, and at SERIALIZABLE two
# requests from one address at the same moment conflicted. The failsafe
# turned the conflict into "no count", and Rack::Attack then wrote 1 over
# the count. So 40 login tries at once from one address were all let
# through. ThrottleStore (lib/throttle_store.rb) adds to a count here in
# one statement at READ COMMITTED, which waits for the other request and
# never loses a count (ADR 0005 decision 11).
#
# - key: Rack::Attack's key. The primary key, so ON CONFLICT can find it.
# - count: how many requests in the window so far. Never below 1.
# - expires_at: the end of the window. A count past it is gone, and
#   ThrottleCount.delete_expired deletes those rows every hour
#   (config/recurring.yml), by this index.
#
# The table records requests, not money. Nothing reads an amount from it
# (money rule 8).
class CreateThrottleCounts < ActiveRecord::Migration[8.1]
  def change
    create_table :throttle_counts, id: false do |t|
      t.text :key, null: false, primary_key: true
      t.integer :count, null: false
      t.datetime :expires_at, null: false
    end

    add_index :throttle_counts, :expires_at

    add_check_constraint :throttle_counts, 'char_length(key) BETWEEN 1 AND 1024', name: 'throttle_counts_key_length'
    add_check_constraint :throttle_counts, 'count >= 1', name: 'throttle_counts_count_positive'
  end
end

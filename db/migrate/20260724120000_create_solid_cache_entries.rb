# frozen_string_literal: true

# The production cache table (solid_cache), replacing MemCachier/memcached.
#
# This table lives in the PRIMARY database on purpose. The solid_cache
# installer assumes a second "cache" database and generates its own
# db/cache_schema.rb plus a database.yml entry. We do not use that layout:
# the whole production database is about 33 MB, so a second database would
# be cost and moving parts for nothing. Leaving :database out of
# config/solid_cache.yml makes SolidCache::Record use the primary
# connection, so this is an ordinary migration in the ordinary schema.
#
# The column and index definitions are copied from the gem's schema template
# (lib/generators/solid_cache/install/templates/db/cache_schema.rb in
# solid_cache 1.0.10). Keep them in step if the gem's schema changes.
class CreateSolidCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :solid_cache_entries do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536_870_912, null: false
      t.datetime :created_at, null: false
      t.integer :key_hash, limit: 8, null: false
      t.integer :byte_size, limit: 4, null: false

      t.index :key_hash, unique: true
      t.index %i[key_hash byte_size]
      t.index :byte_size
    end
  end
end

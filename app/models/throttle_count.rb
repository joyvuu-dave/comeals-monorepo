# typed: strict
# frozen_string_literal: true

# How many requests one Rack::Attack rule has counted from one address in
# one time window (#292, ADR 0005 decision 11). Rack::Attack reaches it
# through ThrottleStore (lib/throttle_store.rb).
#
# Every statement here runs in a transaction of its own at READ COMMITTED,
# not at the SERIALIZABLE the rest of the app uses. Two requests from one
# address at the same moment add to the same row. At SERIALIZABLE,
# PostgreSQL refuses the second one, because the row changed after its
# snapshot. At READ COMMITTED, the second waits for the first to commit
# and then adds to the count the first wrote. Each statement reads and
# writes only the one row it names, and no other transaction reads this
# table, so READ COMMITTED cannot give a wrong count.
#
# The table records requests, not money (money rule 8).
# == Schema Information
#
# Table name: throttle_counts
#
#  count      :integer          not null
#  expires_at :datetime         not null
#  key        :text             not null, primary key
#
# Indexes
#
#  index_throttle_counts_on_expires_at  (expires_at)
#
class ThrottleCount < ApplicationRecord
  extend T::Sig

  self.primary_key = 'key'

  # Adds `amount` to the count for `key` and returns the new count. First
  # an UPDATE adds to the row; a row whose window ended (expires_at at or
  # before `now`) starts again from `amount`, with the new window's end.
  # Only when there is no row does an INSERT add one.
  #
  # Why not one INSERT ... ON CONFLICT DO UPDATE: requests that wait for
  # another request's row are all woken at the same moment, and which one
  # goes first then depends on timing. The count is right either way, but
  # the seeded simulation (spec/simulation) could no longer replay a storm
  # step for step. Requests that wait to UPDATE one row take it in the
  # order they asked, as they do for SELECT ... FOR UPDATE, and an UPDATE
  # of a row that is not there waits for nothing. So the INSERT runs only
  # at the start of a window, and the requests that wait for it are all
  # told the same thing, "there is a row now", whatever order they wake
  # in; each then goes back to the UPDATE.
  INSERT_NEW = T.let(<<~SQL.squish, String)
    INSERT INTO throttle_counts (key, count, expires_at) VALUES (:key, :amount, :expires_at)
    ON CONFLICT (key) DO NOTHING
    RETURNING count
  SQL

  ADD_TO = T.let(<<~SQL.squish, String)
    UPDATE throttle_counts SET
      count = CASE WHEN expires_at > :now THEN count + :amount ELSE :amount END,
      expires_at = CASE WHEN expires_at > :now THEN expires_at ELSE :expires_at END
    WHERE key = :key
    RETURNING count
  SQL

  # Sets the count for `key` to `count`, with a new window's end.
  SET = T.let(<<~SQL.squish, String)
    INSERT INTO throttle_counts (key, count, expires_at) VALUES (:key, :count, :expires_at)
    ON CONFLICT (key) DO UPDATE SET count = EXCLUDED.count, expires_at = EXCLUDED.expires_at
  SQL

  sig do
    params(key: String, amount: Integer, expires_at: ActiveSupport::TimeWithZone,
           now: ActiveSupport::TimeWithZone).returns(Integer)
  end
  def self.add(key, amount, expires_at:, now: Time.current)
    values = { key: key, amount: amount, expires_at: expires_at, now: now }
    read_committed do
      # A second pass happens when another request added the row between
      # this one's UPDATE and its INSERT. The UPDATE then finds it, unless
      # delete_expired deleted it in between, which it does only once the
      # row's window has ended.
      loop do
        count = count_from(ADD_TO, values) || count_from(INSERT_NEW, values)
        break count if count
      end
    end
  end

  sig { params(key: String, count: Integer, expires_at: ActiveSupport::TimeWithZone).void }
  def self.set(key, count, expires_at:)
    sql = sanitize_sql_array([SET, { key: key, count: count, expires_at: expires_at }])
    read_committed { connection.exec_update(sql) }
  end

  # The count for `key` in a window that has not ended, or nil.
  sig { params(key: String, now: ActiveSupport::TimeWithZone).returns(T.nilable(Integer)) }
  def self.current(key, now: Time.current)
    read_committed { where(key: key).where(arel_table[:expires_at].gt(now)).pick(:count) }
  end

  sig { params(key: String).void }
  def self.forget(key)
    read_committed { where(key: key).delete_all }
  end

  # Deletes the rows whose window ended, in one statement by the
  # expires_at index, and returns how many it deleted.
  # config/recurring.yml runs it every hour. At READ COMMITTED like the
  # rest, so it never conflicts with a request's count.
  sig { params(now: ActiveSupport::TimeWithZone).returns(Integer) }
  def self.delete_expired(now: Time.current)
    read_committed { where(expires_at: ..now).delete_all }
  end

  sig { params(sql: String, values: T::Hash[Symbol, T.untyped]).returns(T.nilable(Integer)) }
  def self.count_from(sql, values)
    connection.select_value(sanitize_sql_array([sql, values]))&.then { |count| Integer(count) }
  end
  private_class_method :count_from

  # Runs the block in a transaction of its own at READ COMMITTED. Inside a
  # transaction that is already open, the block joins it at that
  # transaction's level instead: PostgreSQL cannot change the level of an
  # open transaction. Rack::Attack runs before any controller, so in the
  # app no transaction is open; the one open transaction is a spec's.
  sig do
    type_parameters(:Result).params(blk: T.proc.returns(T.type_parameter(:Result))).returns(T.type_parameter(:Result))
  end
  def self.read_committed(&blk) # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- the sig above has to name the block
    return yield if connection.transaction_open?

    transaction(isolation: :read_committed, &blk) # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- the sig above has to name the block
  end
  private_class_method :read_committed
end

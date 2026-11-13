# frozen_string_literal: true

# Issue #274. A bill row is saved from a read of it, and the read can be
# old: the admin bill form is built in one request and saved in the next,
# and a cook can save the same bill from the meal page in between. The
# save then wrote the form's values over the cook's, with no error.
#
# With lock_version, Rails adds "AND lock_version = <the version read>"
# to each UPDATE and DELETE of a bill and adds 1 on each UPDATE. A save
# from an older read matches no row, and Rails raises
# ActiveRecord::StaleObjectError instead of writing. Admin answers that
# with "Someone else changed this after you opened it".
#
# Every write to bills goes through the model (no update_all, no raw SQL,
# no trigger writes the table), so every write adds 1. Existing rows start
# at 0. On PostgreSQL 11 and later a NOT NULL column with a constant
# default is added without rewriting the table.
class AddLockVersionToBills < ActiveRecord::Migration[8.1]
  def change
    add_column :bills, :lock_version, :integer, null: false, default: 0
  end
end

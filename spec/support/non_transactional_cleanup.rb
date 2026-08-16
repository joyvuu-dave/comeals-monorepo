# frozen_string_literal: true

# Cleanup for spec groups that run without transactional fixtures.
#
# Six groups set `use_transactional_tests = false` because they test things a
# never-committed transaction would hide: deferred constraint triggers, row
# locks held across sessions, and snapshot isolation. Their rows really
# commit, so something must remove them. Each group used to keep its own
# delete_all list, and the lists drifted apart (issue #64): some missed
# resident_balances, none touched ledger_check_runs, and one missed table
# made a whole cleanup abort on a foreign-key violation — leaving rows that
# broke hundreds of later specs.
#
# This shared context replaces those lists. Use it instead of setting
# use_transactional_tests directly, so opting out of transactions and
# cleaning up cannot be separated:
#
#   include_context 'with no test transaction'
#
# It cleans with one TRUNCATE rather than ordered delete_all calls:
#
# * One statement for every table, so foreign-key order cannot matter.
#   delete_all had to run children before parents, and a table missing from
#   the list aborted everything after it.
# * Row-level triggers do not fire on TRUNCATE. So this one statement can
#   remove settled rows without the comeals.allow_settled_writes bypass,
#   remove reconciliation_balances without queueing the deferred zero-sum
#   check, and remove communities, whose DELETE trigger
#   (prevent_community_delete) has no bypass at all. The old lists needed a
#   bypass, a SET CONSTRAINTS, and a final TRUNCATE to get around all three;
#   this needs none of them.
# * CASCADE catches any table this list misses that has a foreign key into a
#   listed one, so a forgotten table cannot abort the cleanup. A table with
#   no foreign keys (ledger_check_runs, audits) still needs its own line.
# * Sequences are left alone (no RESTART IDENTITY). No spec depends on
#   absolute id values, and delete_all never reset sequences either, so ids
#   keep counting up exactly as they always did. Restarting them would buy
#   nothing and could collide with stale ids held in memory by the example.
#
# The cleanup runs after each example, as the old lists did, and ALSO before
# each — prepended, so it runs ahead of the group's own before hooks and
# let! data. The before-run is what stops the cascade: even when an earlier
# example's cleanup died, or the database starts dirty (a crashed run, or
# rows written outside the suite), a group starts from empty tables instead
# of inheriting the mess.
module NonTransactionalCleanup
  # Every table the non-transactional groups can write, directly or through
  # their factories. Adding a table means adding one line here — order does
  # not matter, it is all one TRUNCATE. Table names rather than model
  # classes, because this file loads before the app's autoloading is ready
  # for some of them (Audited::Audit, for one).
  TABLES = %w[
    audits
    bills
    meal_residents
    guests
    meal_charges
    reconciliation_balances
    resident_balances
    ledger_check_runs
    meals
    reconciliations
    keys
    residents
    units
    communities
  ].freeze

  # RetryOnConflict for the same reason the old after hooks used it: the app
  # runs at SERIALIZABLE, some of these groups leave a second session that
  # has just written the same rows, and a refused cleanup would leave rows
  # behind for every later example.
  def self.call
    RetryOnConflict.call do
      ActiveRecord::Base.connection.execute(
        "TRUNCATE #{TABLES.join(', ')} CASCADE"
      )
    end
  end
end

RSpec.shared_context 'with no test transaction' do
  self.use_transactional_tests = false

  prepend_before { NonTransactionalCleanup.call }
  after { NonTransactionalCleanup.call }
end

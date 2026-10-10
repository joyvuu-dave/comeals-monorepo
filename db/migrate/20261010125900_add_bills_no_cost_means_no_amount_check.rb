# frozen_string_literal: true

# A bill marked No cost has no amount: "No cost" means the cook spent
# nothing. The Bill model refuses both at once in words
# (Bill::NO_COST_MEANS_NO_AMOUNT); this CHECK makes PostgreSQL refuse it
# from every write that skips the model (update_columns, update_all, a
# rake task, psql).
#
# Step 1 of 3. Added NOT VALID: PostgreSQL checks every row that is added
# or changed from now on, but not the rows already in the table, which
# would fail (27 bills in the production copy of September 2026).
#
#   2. 20261010130000 turns No cost off on every bill that has both.
#   3. 20261010130200 validates this CHECK.
#
# This step comes first so that no new bill with both can be written
# after step 2 has looked: a bill the old code wrote between the fix and
# the CHECK would make step 3 fail. bin/deploy scales web to 0 for a
# deploy with migrations, so only a Heroku Scheduler job could still run
# old code then (until the cutover to Solid Queue). Adding the CHECK
# takes a lock on bills that waits for any open read of bills. If such a
# job holds one for longer than the lock_timeout strong_migrations sets
# (10 seconds), this step fails and nothing of it stays. bin/deploy then
# leaves maintenance on and web at 0, and the deploy can be run again.
class AddBillsNoCostMeansNoAmountCheck < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :bills, 'NOT no_cost OR amount = 0', name: 'bills_no_cost_means_no_amount', validate: false
  end
end

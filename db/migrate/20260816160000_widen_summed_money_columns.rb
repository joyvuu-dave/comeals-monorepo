# frozen_string_literal: true

# Money columns are DECIMAL(12,8): 4 digits before the point, so the
# largest value is 9,999.99999999. A single bill is capped at $9,999.99,
# but these four columns hold sums of bills, and nothing caps a sum:
#
#   reconciliation_balances.amount  a resident's settled balance over a period
#   resident_balances.amount        the running balance
#   meal_charges.amount             one line can cover a whole meal's cost
#   meal_charges.unit_cost          equals the meal's cost when the multiplier is 1
#
# A cook owed $10,000 or more made Reconciliation#persist_balances! raise
# PG::NumericValueOutOfRange mid-settlement (issue #60). DECIMAL(16,8)
# raises the ceiling to about $99,999,999.
#
# bills.amount and the two cap columns stay DECIMAL(12,8): they are single
# user inputs, capped at $9,999.99 by validation, CHECK, and the input
# grammar.
#
# In Postgres, raising a numeric's precision at the same scale changes
# only the catalog: no row is rewritten, so the append-only ledger rows
# are untouched and their immutability triggers never fire.
class WidenSummedMoneyColumns < ActiveRecord::Migration[8.1]
  def up
    change_column :reconciliation_balances, :amount, :decimal, precision: 16, scale: 8, null: false, default: 0
    # safety_assured: resident_balances has a CHECK (the not-NaN guard), so
    # Postgres re-validates it by scanning the table during the type change.
    # The table is a daily-rebuilt cache with one row per resident, so the
    # scan reads well under a hundred rows.
    safety_assured do
      change_column :resident_balances, :amount, :decimal, precision: 16, scale: 8, null: false, default: 0
    end
    change_column :meal_charges, :amount, :decimal, precision: 16, scale: 8, null: false
    change_column :meal_charges, :unit_cost, :decimal, precision: 16, scale: 8, null: false
  end

  def down
    change_column :reconciliation_balances, :amount, :decimal, precision: 12, scale: 8, null: false, default: 0
    safety_assured do
      change_column :resident_balances, :amount, :decimal, precision: 12, scale: 8, null: false, default: 0
    end
    change_column :meal_charges, :amount, :decimal, precision: 12, scale: 8, null: false
    change_column :meal_charges, :unit_cost, :decimal, precision: 12, scale: 8, null: false
  end
end

# frozen_string_literal: true

# A bill marked No cost has no amount. Step 3 of 3: check the rows
# already in the bills table against the CHECK
# bills_no_cost_means_no_amount.
#
# Step 1 (20261010125900) added the CHECK NOT VALID, so PostgreSQL has
# refused every new or changed bill with both since then. Step 2
# (20261010130000) turned No cost off on every bill that had both before.
# So no row breaks the CHECK. If one does (only a write that went around
# the CHECK can make one), this stops and lists each one
# (refuse_bills_with_both), so the release fails and the old release
# keeps serving.
#
# VALIDATE CONSTRAINT takes a SHARE UPDATE EXCLUSIVE lock: bills can
# still be read and written while it reads the table.
class ValidateBillsNoCostMeansNoAmountCheck < ActiveRecord::Migration[8.1]
  NAME = 'bills_no_cost_means_no_amount'
  EXPRESSION = 'NOT no_cost OR amount = 0'

  def up
    refuse_bills_with_both
    validate_check_constraint :bills, name: NAME
  end

  # Back to the state after step 2: PostgreSQL cannot mark a CHECK as not
  # validated again, so it is dropped and added back NOT VALID.
  def down
    remove_check_constraint :bills, name: NAME
    add_check_constraint :bills, EXPRESSION, name: NAME, validate: false
  end

  private

  # The validation would fail on such a row anyway, but with a message
  # about a constraint. This one names each bill, its meal's date and its
  # amount, so the person deploying knows which ones to fix.
  def refuse_bills_with_both
    rows = select_rows(<<~SQL.squish)
      SELECT bills.id, meals.date, bills.amount
      FROM bills JOIN meals ON meals.id = bills.meal_id
      WHERE bills.no_cost AND bills.amount <> 0
      ORDER BY meals.date, bills.id
    SQL
    return if rows.empty?

    list = rows.map do |id, date, amount|
      "bill #{id} (#{date}, #{ActiveSupport::NumberHelper.number_to_currency(BigDecimal(amount.to_s))})"
    end
    raise "#{rows.size} bill(s) have No cost and an amount: #{list.join(', ')}. " \
          'Migration 20261010130000 turned No cost off on every such bill, and the CHECK refuses a new one, ' \
          'so a write went around the CHECK. Turn No cost off on each one, then run this migration again.'
  end
end

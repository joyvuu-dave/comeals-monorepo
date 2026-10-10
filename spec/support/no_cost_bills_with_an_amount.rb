# frozen_string_literal: true

# A bill marked No cost that also has an amount. The Bill model refuses
# one since 2026-10-10 (Bill::NO_COST_MEANS_NO_AMOUNT), and so does the
# CHECK bills_no_cost_means_no_amount. Migration 20261010130000 turned No
# cost off on every bill that had both, and its spec needs such bills to
# turn off.
#
# This writes one the way the app did before April 2026: the bill saved
# with No cost and $0, then the amount saved through the model, so the
# history has both rows. The amount is saved without the validation, and
# with the CHECK removed for that one write and added back NOT VALID, as
# it was before migration 20261010130200 validated it. ALTER TABLE is
# part of the transaction, so the example's transaction puts the CHECK
# back as it was, and if the block raises, the savepoint does. It needs
# the example's transaction: outside one, removing the CHECK would be
# committed.
module NoCostBillsWithAnAmount
  CHECK = 'bills_no_cost_means_no_amount'

  def no_cost_bill_with_an_amount(meal:, resident:, amount:)
    connection = ActiveRecord::Base.connection
    raise 'no_cost_bill_with_an_amount needs the test transaction' unless connection.transaction_open?

    bill = FactoryBot.create(:bill, meal: meal, resident: resident, community: meal.community, amount: 0,
                                    no_cost: true)
    ActiveRecord::Base.transaction(requires_new: true) do
      connection.remove_check_constraint(:bills, name: CHECK)
      bill.amount = BigDecimal(amount.to_s)
      bill.save!(validate: false)
      connection.add_check_constraint(:bills, 'NOT no_cost OR amount = 0', name: CHECK, validate: false)
    end
    bill
  end
end

RSpec.configure { |config| config.include NoCostBillsWithAnAmount }

# frozen_string_literal: true

class AddCheckConstraintToResidentBalancesAmount < ActiveRecord::Migration[8.1]
  def up
    # PostgreSQL numeric supports NaN as a special value. BigDecimal('NaN') can
    # slip through Rails into the database if a calculation produces NaN (e.g.,
    # 0/0). The idiom `amount = amount` is false for NaN in PostgreSQL, so this
    # constraint rejects it. This is the database-level last line of defense for
    # the upsert_all in billing:recalculate, which bypasses model validations.
    add_check_constraint :resident_balances, 'amount = amount', name: 'resident_balances_amount_not_nan'
  end

  def down
    remove_check_constraint :resident_balances, name: 'resident_balances_amount_not_nan'
  end
end

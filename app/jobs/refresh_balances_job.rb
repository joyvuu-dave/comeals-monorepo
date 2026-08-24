# frozen_string_literal: true

# Make every resident's running balance match the source data. Safe at any
# time: the balance table is a cache (CLAUDE.md, "Balances are always
# derived"), and BalanceRecalculation rebuilds all of it from the
# unreconciled meals in one consistent snapshot.
class RefreshBalancesJob < RecurringJob
  HEALTHCHECK = 'billing-recalculate'

  def run
    { balances_written: BalanceRecalculation.call }
  end
end

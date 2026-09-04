# typed: true
# frozen_string_literal: true

# What one meal cost, for a screen. Admin reads this; nothing here
# feeds the ledger.
#
# A settled meal reads its stored meal_charges — the numbers the
# settlement actually used. Recomputing them live would apply today's
# community cap to a meal settled under an older one, and the screen
# would quietly disagree with the ledger. A meal settled before
# 2026-08-02 has no charges on purpose (the backfill decision in
# docs/money-path-observability.md); `for` returns nil there, and the
# screen shows nothing rather than a number nobody vouched for.
#
# An open meal computes through MealLedger, the one place the money
# arithmetic lives. Callers that show many meals should preload
# :bills, :meal_residents, :guests, and :meal_charges — MealLedger
# runs no queries, and the charges read is one association.
class MealCostSummary
  def self.for(meal)
    if meal.reconciled?
      from_charges(meal)
    else
      MealLedger.new([meal]).summary_for(meal)
    end
  end

  # The credit lines carry everything the summary needs: bill_amount is
  # what the cooks spent (no_cost bills produce no line, matching
  # total_cost's definition), the credit amounts sum to the effective
  # cost, and every line carries the meal's unit_cost.
  def self.from_charges(meal)
    charges = meal.meal_charges.to_a
    return chargeless(meal) if charges.empty?

    credits = charges.select(&:credit?)
    MealLedger::Summary.new(
      total_cost: credits.sum(BigDecimal('0'), &:bill_amount),
      effective_cost: credits.sum(BigDecimal('0'), &:amount),
      unit_cost: charges.first.unit_cost,
      subsidized: charges.any?(&:subsidized?)
    )
  end

  # A settled meal with no lines is one of two stories. A meal nobody
  # attended is swept but charges no one on purpose — the cooks absorb
  # the receipts. Its receipts are immutable once settled, so summing
  # them here cannot drift; the zeros say "nothing was charged". A meal
  # WITH attendance and no lines was settled before line items existed
  # (2026-08-02): unrecorded, so show nothing rather than a recomputed
  # number the settlement never used.
  def self.chargeless(meal)
    return nil if meal.meal_residents.any? || meal.guests.any?

    MealLedger::Summary.new(
      total_cost: meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount),
      effective_cost: BigDecimal('0'),
      unit_cost: BigDecimal('0'),
      subsidized: false
    )
  end

  private_class_method :from_charges, :chargeless
end

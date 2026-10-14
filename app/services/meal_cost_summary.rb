# typed: strict
# frozen_string_literal: true

# What one meal cost, for a screen. Admin reads this; nothing here
# feeds the ledger.
#
# A settled meal reads its stored meal_charges — the numbers the
# settlement actually used. The meal's rows are frozen (its cap too: a
# meal copies the community cap when it is made), but the ledger's rules
# are not. ADR 0008 changed how a share is split, so a meal settled
# before that change can compute to different lines today, and a screen
# that computed them would quietly disagree with the ledger. A meal
# settled before 2026-08-02 has no charges on purpose (the backfill
# decision in docs/money-path-observability.md); `for` returns nil
# there, and the screen shows nothing rather than a number nobody
# vouched for.
#
# An open meal computes through MealLedger, the one place the money
# arithmetic lives. Callers that show many meals should preload
# :bills, :meal_residents, :guests, and :meal_charges — MealLedger
# runs no queries, and the charges read is one association.
class MealCostSummary
  extend T::Sig

  sig { params(meal: Meal).returns(T.nilable(MealLedger::Summary)) }
  def self.for(meal)
    if meal.reconciled?
      from_charges(meal)
    else
      MealLedger.new([meal]).summary_for(meal)
    end
  end

  # What the meal costs by its rows as they are now, for the meal's own
  # page. A settled meal that was corrected (ADR 0011 rule 6) has changed
  # rows, so its stored lines show what it was settled at, not what it
  # costs: this works it out from the rows, as for an open meal. The
  # settlement's page keeps `for`, the numbers it settled. Every other
  # meal reads the same as `for`.
  sig { params(meal: Meal).returns(T.nilable(MealLedger::Summary)) }
  def self.now(meal)
    return self.for(meal) unless meal.reconciled? && meal.meal_corrections.any?

    MealLedger.new([meal]).summary_for(meal)
  end

  # The credit lines carry everything the summary needs: bill_amount is
  # what the cooks spent (no_cost bills produce no line, matching
  # total_cost's definition), the credit amounts sum to the effective
  # cost, and every line carries the meal's unit_cost.
  sig { params(meal: Meal).returns(T.nilable(MealLedger::Summary)) }
  def self.from_charges(meal)
    charges = meal.meal_charges.to_a
    first = charges.first
    return chargeless(meal) if first.nil?

    credits = charges.select(&:credit?)
    MealLedger::Summary.new(
      total_cost: credits.sum(BigDecimal('0')) { |credit| T.must(credit.bill_amount) },
      effective_cost: credits.sum(BigDecimal('0')) { |credit| T.must(credit.amount) },
      unit_cost: T.must(first.unit_cost),
      subsidized: charges.any?(&:subsidized?)
    )
  end

  # A settled meal with no lines is one of two stories. A meal nobody
  # attended is swept but charges no one on purpose — the cooks absorb
  # the receipts. Its receipts are immutable once settled, so summing
  # them here cannot drift; the zeros say "nothing was charged". Its
  # cooks were credited nothing, so it is subsidized when they spent
  # anything, the same as MealLedger says of an open meal nobody ate
  # (#94). (A settlement holds such a meal back when a receipt has money
  # on it, since 2026-09-10; older ones were swept.) A meal WITH
  # attendance and no lines was settled before line items existed
  # (2026-08-02): unrecorded, so show nothing rather than a recomputed
  # number the settlement never used.
  sig { params(meal: Meal).returns(T.nilable(MealLedger::Summary)) }
  def self.chargeless(meal)
    return nil if meal.meal_residents.any? || meal.guests.any?

    spent = meal.bills.reject(&:no_cost).sum(BigDecimal('0')) { |bill| T.must(bill.amount) }
    MealLedger::Summary.new(
      total_cost: spent,
      effective_cost: BigDecimal('0'),
      unit_cost: BigDecimal('0'),
      subsidized: spent.positive?
    )
  end

  private_class_method :from_charges, :chargeless
end

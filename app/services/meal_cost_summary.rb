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
# that computed them would show other numbers than the ledger, with no
# warning. A meal settled before 2026-08-02 has no charges on purpose (the
# backfill decision in docs/money-path-observability.md); `for` returns
# nil there, and the screen shows nothing rather than a number nobody
# vouched for.
#
# An open meal computes through MealLedger, the one place the money
# arithmetic lives. Callers that show many meals should preload
# :bills, :meal_residents, :guests, :meal_charges and :meal_corrections —
# MealLedger runs no queries, and the charges read is one association.
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
  # the receipts, and the zeros say "nothing was charged". Its cooks were
  # credited nothing, so it is subsidized when they spent anything, the
  # same as MealLedger says of an open meal nobody ate (#94). (A
  # settlement holds such a meal back when a receipt has money on it,
  # since 2026-09-10; older ones were swept.) A meal WITH attendance and
  # no lines was settled before line items existed (2026-08-02):
  # unrecorded, so show nothing rather than a recomputed number the
  # settlement never used.
  #
  # Both read the rows as they were when the meal settled. A correction
  # (ADR 0011 rule 6) can change a cook's cost, add or remove a cook, and
  # add or remove an eater or a guest later, so the rows now are not
  # always the rows it settled (#177). The correction's record keeps each
  # value before it changed, and the summary works back from the rows now
  # to the rows then. Every edit has every key (MealCorrecting::Edits),
  # so the reads use fetch: a record without one is an error, not a nil.
  sig { params(meal: Meal).returns(T.nilable(MealLedger::Summary)) }
  def self.chargeless(meal)
    edits = meal.meal_corrections.flat_map { |correction| T.let(correction.edits, T::Array[Edit]) }
    return nil if eaters_when_settled(meal, edits).positive?

    spent = costs_when_settled(meal, edits).reject(&:last).sum(BigDecimal('0'), &:first)
    MealLedger::Summary.new(
      total_cost: spent,
      effective_cost: BigDecimal('0'),
      unit_cost: BigDecimal('0'),
      subsidized: spent.positive?
    )
  end

  # One edit in a correction's record (MealCorrecting::Edits::Done).
  Edit = T.type_alias { T::Hash[String, T.untyped] }

  # The edits that add or remove a person who ate, or change their price.
  EATER_EDITS = T.let(%w[eater guest].freeze, T::Array[String])

  # How many eaters and guests the meal had when it settled: the ones it
  # has now, plus each one a correction removed, minus each one a
  # correction added. A change of price adds and removes no one.
  sig { params(meal: Meal, edits: T::Array[Edit]).returns(Integer) }
  def self.eaters_when_settled(meal, edits)
    edits.select { |edit| EATER_EDITS.include?(edit.fetch('what')) }
         .sum(meal.meal_residents.size + meal.guests.size) do |edit|
      (edit.fetch('to').nil? ? 1 : 0) - (edit.fetch('from').nil? ? 1 : 0)
    end
  end

  # Each cook's cost when the meal settled, as [amount, no_cost]. A cook
  # no correction names has the cost on their bill now. For a cook a
  # correction does name, the first edit that names them has their cost
  # before it, or nothing when they were not a cook then. The same rule
  # as Reconciliation.settled_dinner_cooks.
  sig { params(meal: Meal, edits: T::Array[Edit]).returns(T::Array[[BigDecimal, T::Boolean]]) }
  def self.costs_when_settled(meal, edits)
    costs = meal.bills.to_h { |bill| [T.must(bill.resident_id), [T.must(bill.amount), T.must(bill.no_cost)]] }
    named = Set.new
    edits.each do |edit|
      cook_id = edit.fetch('resident_id')
      next unless edit.fetch('what') == 'cost' && named.add?(cook_id)

      before = edit.fetch('from')
      if before.nil?
        costs.delete(cook_id)
      else
        costs[cook_id] = [BigDecimal(before.fetch('amount')), before.fetch('no_cost')]
      end
    end
    costs.values
  end

  private_class_method :from_charges, :chargeless, :eaters_when_settled, :costs_when_settled
end

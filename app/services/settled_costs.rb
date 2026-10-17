# typed: strict
# frozen_string_literal: true

# Each cook's cost on a settled dinner as it was when the dinner settled.
#
# A dinner's bills now are not always the ones its settlement settled. A
# correction (ADR 0011 rule 6) changes a cook's cost, adds a cook or
# removes one, and its record keeps each cost before the change
# (MealCorrecting::Edits). So a cook no correction names has the cost on
# their bill now. For a cook a correction does name, the first edit that
# names them has their cost before it, or nothing when they were not a
# cook then. Reconciliation.settled_dinner_cooks finds the cooks by the
# same rule, in SQL.
#
# The meal should come with its bills and its corrections loaded when
# the caller reads many meals; this runs no other query. It does not ask
# whether the dinner was cancelled: a cancelled dinner has no cooks
# (ADR 0011 rule 11), and the caller leaves it out.
class SettledCosts
  extend T::Sig

  # [amount, no_cost], as on a bill.
  Cost = T.type_alias { [BigDecimal, T::Boolean] }

  # One edit in a correction's record (MealCorrecting::Edits::Done).
  Edit = T.type_alias { T::Hash[String, T.untyped] }

  # Every edit of the meal's corrections, in the order they were made.
  sig { params(meal: Meal).returns(T::Array[Edit]) }
  def self.edits(meal)
    meal.meal_corrections.flat_map { |correction| T.let(correction.edits, T::Array[Edit]) }
  end

  # { cook's resident_id => their cost } when the meal settled. Every edit
  # has every key (MealCorrecting::Edits), so the reads use fetch: a
  # record without one is an error, not a nil.
  sig { params(meal: Meal).returns(T::Hash[Integer, Cost]) }
  def self.of(meal)
    costs = T.let(meal.bills.to_h { |bill| [T.must(bill.resident_id), [T.must(bill.amount), T.must(bill.no_cost)]] },
                  T::Hash[Integer, Cost])
    named = Set.new
    edits(meal).each do |edit|
      cook_id = edit.fetch('resident_id')
      next unless edit.fetch('what') == 'cost' && named.add?(cook_id)

      before = edit.fetch('from')
      if before.nil?
        costs.delete(cook_id)
      else
        costs[cook_id] = [BigDecimal(before.fetch('amount')), before.fetch('no_cost')]
      end
    end
    costs
  end
end

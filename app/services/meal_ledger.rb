# typed: true
# frozen_string_literal: true

# The one place the money arithmetic lives.
#
# Give it a set of meals; it returns the individual debits and credits those
# meals produce, and the per-resident totals of those lines. Both callers on
# the money path use it:
#
#   - Reconciliation#settlement_balances — settled meals, then rounded to
#     cents by largest-remainder allocation.
#   - lib/tasks/billing/recalculate.rake — unreconciled meals, the running
#     balance, stored at full precision.
#
# Before this existed those two carried their own copy of the same rules, and
# nothing checked that the copies agreed. A difference between them would be
# hard to see: every number looks reasonable on its own, both ledgers still
# sum to zero, and the only symptom is a balance that moves at settlement for
# no reason a resident can find. spec/tasks/settlement_matches_running_balance_spec.rb
# is what proved they agreed at the moment they were merged.
#
# Resident#calc_balance is a third copy, deliberately kept. It is not used in
# production. Its whole job is to be written independently, so that it
# disagrees when this class is wrong. Do not route it through here.
#
# == This class runs no queries
#
# It reads `bills`, `meal_residents` and `guests` off the meals it is handed,
# so callers must preload those three. That is not only about N+1: the rake
# task reads its meals inside one SERIALIZABLE READ ONLY snapshot
# (app/services/snapshot_read.rb), and a query fired from in here would run
# outside that snapshot and could see a different state of the ledger.
#
# == Signs
#
# `amount` is signed, and positive means the community owes the resident.
# A credit is positive, a debit is negative, and a resident's balance is the
# plain sum of their lines. Carrying the sign on the line, rather than
# subtracting by kind at the end, is what stops a sign error from being
# possible in the first place.
#
# == Money
#
# Every amount is BigDecimal at full precision. Nothing here rounds. Rounding
# to cents happens once, at settlement, in Reconciliation#allocate_to_cents.
class MealLedger
  # One debit or credit, for one resident, on one meal.
  #
  #   meal_id, resident_id  what this line is about
  #   kind                  :credit, :debit, or :guest_debit
  #   amount                signed, full precision (see Signs above)
  #   multiplier            units eaten; nil on a credit, which is not per-unit
  #   unit_cost             the meal's cost per unit of multiplier
  #   bill_amount           what the cook actually spent, before any cap;
  #                         nil on a debit. On a subsidized meal this differs
  #                         from the credit, and is the only way to explain
  #                         why the cook was not paid back in full.
  Line = Data.define(:meal_id, :resident_id, :kind, :amount, :multiplier, :unit_cost, :bill_amount)

  ZERO = BigDecimal('0')

  def initialize(meals)
    @meals = meals
  end

  # Every line these meals produce, in no particular order.
  def lines
    @lines ||= @meals.flat_map { |meal| lines_for(meal) }
  end

  # The per-meal numbers a screen shows: what the cooks spent, what the
  # eaters are charged for (lower on a subsidized meal), the cost per
  # unit of multiplier, and whether the community subsidized it. This is
  # the display face of the same financials_for pass the lines are built
  # from — screens must read it (via MealCostSummary), never re-derive
  # the arithmetic.
  Summary = Data.define(:total_cost, :effective_cost, :unit_cost, :subsidized)

  def summary_for(meal)
    financials = financials_for(meal)
    Summary.new(
      total_cost: financials[:total_cost],
      effective_cost: financials[:effective_cost],
      unit_cost: financials[:unit_cost],
      subsidized: financials[:effective_cost] < financials[:total_cost]
    )
  end

  # Per-resident totals, as { resident_id => BigDecimal }.
  #
  # The caller passes the residents it wants, and every one of them gets an
  # entry — zero for a resident who neither ate nor cooked. Lines belonging
  # to a resident outside that set are dropped, which is the behavior both
  # callers had before: each asked for its community's residents, and a row
  # cannot belong to anyone else (foreign keys, plus the destroy guards on
  # Resident).
  def balances(resident_ids)
    totals = Hash.new(ZERO)
    lines.each { |line| totals[line.resident_id] += line.amount }

    resident_ids.index_with { |resident_id| totals[resident_id] }
  end

  private

  def lines_for(meal)
    financials = financials_for(meal)

    credit_lines(meal, financials) + debit_lines(meal, financials)
  end

  # What one meal costs per unit of multiplier, and the two totals the credit
  # calculation needs.
  #
  # total_cost is what the cooks spent. effective_cost is what the eaters are
  # charged for, which is lower when the meal is capped and the cooks spent
  # more than the cap allows. The community absorbs the difference.
  #
  # Nobody can be charged a share of a meal with no units of multiplier — a
  # meal attended only by babies. Everything is zero there, which also means
  # the cooks get no credit and absorb the cost themselves.
  def financials_for(meal)
    total_multiplier = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)
    return { unit_cost: ZERO, total_cost: ZERO, effective_cost: ZERO } if total_multiplier.zero?

    total_cost = meal.bills.reject(&:no_cost).sum(ZERO, &:amount)
    effective_cost = total_cost

    if meal.capped?
      max_cost = meal.cap * total_multiplier
      effective_cost = max_cost if total_cost > max_cost
    end

    { unit_cost: effective_cost / total_multiplier, total_cost: total_cost, effective_cost: effective_cost }
  end

  # A no_cost bill records that someone cooked without spending money. It
  # produces no line at all, so it neither credits its cook nor raises what
  # anyone is charged.
  def credit_lines(meal, financials)
    meal.bills.reject(&:no_cost).map do |bill|
      Line.new(
        meal_id: meal.id,
        resident_id: bill.resident_id,
        kind: :credit,
        amount: credit_amount(bill, financials),
        multiplier: nil,
        unit_cost: financials[:unit_cost],
        bill_amount: bill.amount
      )
    end
  end

  # On a subsidized meal each cook is credited their share of what the eaters
  # were actually charged, in proportion to what they spent. Two cooks who
  # spent $40 and $20 on a meal capped at $18 are credited $12 and $6.
  def credit_amount(bill, financials)
    return ZERO if financials[:total_cost].zero?
    return bill.amount unless financials[:effective_cost] < financials[:total_cost]

    (bill.amount / financials[:total_cost]) * financials[:effective_cost]
  end

  def debit_lines(meal, financials)
    residents = meal.meal_residents.map { |attendance| debit_line(meal, attendance, financials, :debit) }
    guests = meal.guests.map { |guest| debit_line(meal, guest, financials, :guest_debit) }

    residents + guests
  end

  # A guest's debit goes to the resident who brought them, which is why a
  # guest line carries a resident_id at all.
  def debit_line(meal, attendance, financials, kind)
    Line.new(
      meal_id: meal.id,
      resident_id: attendance.resident_id,
      kind: kind,
      amount: -(financials[:unit_cost] * attendance.multiplier),
      multiplier: attendance.multiplier,
      unit_cost: financials[:unit_cost],
      bill_amount: nil
    )
  end
end

# typed: strict
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
  extend T::Sig

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
  class Line < T::Struct
    const :meal_id, Integer
    const :resident_id, Integer
    const :kind, Symbol
    const :amount, BigDecimal
    const :multiplier, T.nilable(Integer)
    const :unit_cost, BigDecimal
    const :bill_amount, T.nilable(BigDecimal)
  end

  ZERO = T.let(BigDecimal('0'), BigDecimal)

  # The three numbers one meal's lines are built from. Private to this
  # class; screens get them through Summary.
  class Financials < T::Struct
    const :unit_cost, BigDecimal
    const :total_cost, BigDecimal
    const :effective_cost, BigDecimal
  end
  private_constant :Financials

  # Callers hand in an Array, not a relation, so that every query has
  # already run (see "This class runs no queries" above).
  sig { params(meals: T::Array[Meal]).void }
  def initialize(meals)
    @meals = meals
    @lines = T.let(nil, T.nilable(T::Array[Line]))
  end

  # Every line these meals produce, in no particular order.
  sig { returns(T::Array[Line]) }
  def lines
    @lines ||= @meals.flat_map { |meal| lines_for(meal) }
  end

  # The per-meal numbers a screen shows: what the cooks spent, what the
  # eaters are charged for (lower on a subsidized meal), the cost per
  # unit of multiplier, and whether the community subsidized it. This is
  # the display face of the same financials_for pass the lines are built
  # from — screens must read it (via MealCostSummary), never re-derive
  # the arithmetic.
  class Summary < T::Struct
    const :total_cost, BigDecimal
    const :effective_cost, BigDecimal
    const :unit_cost, BigDecimal
    const :subsidized, T::Boolean
  end

  sig { params(meal: Meal).returns(Summary) }
  def summary_for(meal)
    financials = financials_for(meal)
    Summary.new(
      total_cost: financials.total_cost,
      effective_cost: financials.effective_cost,
      unit_cost: financials.unit_cost,
      subsidized: financials.effective_cost < financials.total_cost
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
  sig { params(resident_ids: T::Array[Integer]).returns(T::Hash[Integer, BigDecimal]) }
  def balances(resident_ids)
    totals = T.let({}, T::Hash[Integer, BigDecimal])
    lines.each { |line| totals[line.resident_id] = totals.fetch(line.resident_id, ZERO) + line.amount }

    resident_ids.index_with { |resident_id| totals.fetch(resident_id, ZERO) }
  end

  private

  sig { params(meal: Meal).returns(T::Array[Line]) }
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
  sig { params(meal: Meal).returns(Financials) }
  def financials_for(meal)
    total_multiplier = meal.meal_residents.sum { |attendance| T.must(attendance.multiplier) } +
                       meal.guests.sum { |guest| T.must(guest.multiplier) }
    return Financials.new(unit_cost: ZERO, total_cost: ZERO, effective_cost: ZERO) if total_multiplier.zero?

    total_cost = meal.bills.reject(&:no_cost).sum(ZERO) { |bill| T.must(bill.amount) }
    effective_cost = total_cost

    cap = meal.cap # nil means uncapped (Meal#capped?)
    unless cap.nil?
      max_cost = cap * total_multiplier
      effective_cost = max_cost if total_cost > max_cost
    end

    Financials.new(unit_cost: effective_cost / total_multiplier, total_cost: total_cost,
                   effective_cost: effective_cost)
  end

  # A no_cost bill records that someone cooked without spending money. It
  # produces no line at all, so it neither credits its cook nor raises what
  # anyone is charged.
  sig { params(meal: Meal, financials: Financials).returns(T::Array[Line]) }
  def credit_lines(meal, financials)
    meal.bills.reject(&:no_cost).map do |bill|
      Line.new(
        meal_id: T.must(meal.id),
        resident_id: T.must(bill.resident_id),
        kind: :credit,
        amount: credit_amount(bill, financials),
        multiplier: nil,
        unit_cost: financials.unit_cost,
        bill_amount: T.must(bill.amount)
      )
    end
  end

  # On a subsidized meal each cook is credited their share of what the eaters
  # were actually charged, in proportion to what they spent. Two cooks who
  # spent $40 and $20 on a meal capped at $18 are credited $12 and $6.
  sig { params(bill: Bill, financials: Financials).returns(BigDecimal) }
  def credit_amount(bill, financials)
    amount = T.must(bill.amount)
    return ZERO if financials.total_cost.zero?
    return amount unless financials.effective_cost < financials.total_cost

    (amount / financials.total_cost) * financials.effective_cost
  end

  sig { params(meal: Meal, financials: Financials).returns(T::Array[Line]) }
  def debit_lines(meal, financials)
    residents = meal.meal_residents.map { |attendance| debit_line(meal, attendance, financials, :debit) }
    guests = meal.guests.map { |guest| debit_line(meal, guest, financials, :guest_debit) }

    residents + guests
  end

  # A guest's debit goes to the resident who brought them, which is why a
  # guest line carries a resident_id at all.
  sig do
    params(meal: Meal, attendance: T.any(MealResident, Guest), financials: Financials, kind: Symbol)
      .returns(Line)
  end
  def debit_line(meal, attendance, financials, kind)
    multiplier = T.must(attendance.multiplier)
    Line.new(
      meal_id: T.must(meal.id),
      resident_id: T.must(attendance.resident_id),
      kind: kind,
      amount: -(financials.unit_cost * multiplier),
      multiplier: multiplier,
      unit_cost: financials.unit_cost,
      bill_amount: nil
    )
  end
end

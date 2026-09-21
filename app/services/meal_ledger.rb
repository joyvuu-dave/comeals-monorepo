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
#     balance, stored as it is.
#
# Before this existed those two carried their own copy of the same rules, and
# nothing checked that the copies agreed. A difference between them would be
# hard to see: every number looks reasonable on its own, both ledgers still
# sum to zero, and the only symptom is a balance that moves at settlement for
# no reason a resident can find. spec/tasks/settlement_matches_running_balance_spec.rb
# is what proved they agreed at the moment they were merged.
#
# spec/support/oracle/plain_ledger.rb is a second copy, written from the
# rules by someone who had not read this class, so that it disagrees when
# this class is wrong. Do not edit it to match this class.
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
# Every amount is a whole number of units of 10^-8 dollars, the grain of the
# money columns (MODELS.md, "The ledger grain"). Nothing here divides: a
# share of a meal's cost is allocated by LargestRemainderSplit, so a meal's
# lines sum to exactly zero and what is computed is what the column stores.
# Rounding to cents happens once, at settlement, in
# Settlement.allocate_to_cents.
#
# This replaced "full precision" on 2026-09-17 (ADR 0008, #85). Lines used
# to be divided at about twenty digits and rounded to eight by the column on
# the way in, and the rounded-off part went nowhere, so a meal's stored
# lines summed to whatever the rounding dropped and the daily check needed
# an epsilon.
class MealLedger
  extend T::Sig

  # One debit or credit, for one resident, on one meal.
  #
  #   meal_id, resident_id  what this line is about
  #   kind                  :credit, :debit, or :guest_debit
  #   amount                signed, at the ledger grain (see Signs above)
  #   multiplier            units eaten; nil on a credit, which is not per-unit
  #   unit_cost             the meal's cost per unit of multiplier, cut to the
  #                         grain; a figure for a screen, no line is computed
  #                         from it
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

  # One unit of the ledger grain, as a BigDecimal, and the number of them
  # in a dollar.
  UNIT = T.let(BigDecimal('0.00000001'), BigDecimal)
  UNITS_PER_DOLLAR = T.let(100_000_000, Integer)

  # The numbers one meal's lines are built from, in units. Private to this
  # class; screens get them through Summary.
  class Financials < T::Struct
    const :total_multiplier, Integer
    const :total_units, Integer
    const :effective_units, Integer
    const :unit_cost, BigDecimal
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
    financials = financials_for(meal, eaters(meal), spent_by(cooks(meal)))
    Summary.new(
      total_cost: amount(financials.total_units),
      effective_cost: amount(financials.effective_units),
      unit_cost: financials.unit_cost,
      subsidized: subsidized?(financials)
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

  # A dollar amount as a whole number of units. Every amount that reaches
  # the ledger is at the grain already (a bill is whole cents, a cap is a
  # DECIMAL(12,8) column); one that is not is a wrong value, and a wrong
  # value must not reach the ledger.
  sig { params(amount: BigDecimal).returns(Integer) }
  def self.units(amount)
    scaled = amount * UNITS_PER_DOLLAR
    raise ArgumentError, "#{amount.to_s('F')} is not a whole number of 10^-8 dollars" unless scaled.frac.zero?

    scaled.to_i
  end

  private

  # Units back to dollars. Multiplying by a power of ten is exact. UNIT on
  # the left: Integer#* would first coerce the Integer into a BigDecimal,
  # one more object per line.
  sig { params(units: Integer).returns(BigDecimal) }
  def amount(units)
    UNIT * units
  end

  sig { params(financials: Financials).returns(T::Boolean) }
  def subsidized?(financials)
    financials.effective_units < financials.total_units
  end

  # The eaters, the cooks and what they spent are worked out once per meal
  # here and handed down: a settlement builds a few thousand lines, and
  # spec/services/money_path_allocations_spec.rb pins what that allocates.
  sig { params(meal: Meal).returns(T::Array[Line]) }
  def lines_for(meal)
    people = eaters(meal)
    bills = cooks(meal)
    spent = spent_by(bills)
    financials = financials_for(meal, people, spent)

    credit_lines(meal, bills, spent, financials) + debit_lines(meal, people, financials)
  end

  # What each cook spent, in units, in the same order as the bills.
  sig { params(bills: T::Array[Bill]).returns(T::Array[Integer]) }
  def spent_by(bills)
    bills.map { |bill| self.class.units(T.must(bill.amount)) }
  end

  # What one meal's lines are built from: the total multiplier, what the
  # cooks spent, and what the eaters are charged for.
  #
  # total_units is what the cooks spent. effective_units is what the eaters
  # are charged for, which is lower when the meal is capped and the cooks
  # spent more than the cap allows. The community absorbs the difference.
  #
  # Nobody can be charged a share of a meal with no units of multiplier — a
  # meal attended only by babies. Every line is zero there, which also means
  # the cooks get no credit and absorb the cost themselves. The lines still
  # exist: a zero line is a fact about what happened, and a settled meal's
  # screen reads its lines (MealCostSummary).
  #
  # unit_cost is the one quotient in the ledger, and it is cut to the grain
  # (rounded down) here, in one place, for screens. No line is computed
  # from it.
  sig do
    params(meal: Meal, people: T::Array[T.any(MealResident, Guest)], spent: T::Array[Integer]).returns(Financials)
  end
  def financials_for(meal, people, spent)
    total_multiplier = people.sum { |eater| T.must(eater.multiplier) }
    if total_multiplier.zero?
      return Financials.new(total_multiplier: 0, total_units: 0, effective_units: 0, unit_cost: ZERO)
    end

    total_units = spent.sum
    effective_units = total_units

    cap = meal.cap # nil means uncapped (Meal#capped?)
    unless cap.nil?
      max_units = self.class.units(cap) * total_multiplier
      effective_units = max_units if total_units > max_units
    end

    Financials.new(total_multiplier: total_multiplier, total_units: total_units, effective_units: effective_units,
                   unit_cost: amount(effective_units / total_multiplier))
  end

  # A no_cost bill records that someone cooked without spending money. It
  # produces no line at all, so it neither credits its cook nor raises what
  # anyone is charged. One bill per (meal, resident), so resident id is the
  # whole tie-break order.
  sig { params(meal: Meal).returns(T::Array[Bill]) }
  def cooks(meal)
    meal.bills.reject(&:no_cost).sort_by { |bill| T.must(bill.resident_id) }
  end

  # Everyone who is charged, in tie-break order: lowest resident id first,
  # an attendee line before a guest line of the same resident, and between
  # two guests of one host the lower guest id.
  #
  # A comparison block rather than sort_by, which would build a key array
  # per eater (see lines_for).
  sig { params(meal: Meal).returns(T::Array[T.any(MealResident, Guest)]) }
  def eaters(meal)
    people = T.let(meal.meal_residents.to_a + meal.guests.to_a, T::Array[T.any(MealResident, Guest)])
    people.sort do |a, b|
      order = T.must(a.resident_id) <=> T.must(b.resident_id)
      order = kind_rank(a) <=> kind_rank(b) if order.zero?
      order = T.must(a.id) <=> T.must(b.id) if order.zero? && a.is_a?(Guest)
      order
    end
  end

  # 0 for an attendee, 1 for a guest. A method, not a ternary on each side
  # of the comparison above: which side of a tied comparison holds the
  # guest depends on the sort algorithm, and Ruby uses the C library's
  # sort on Linux and its own on macOS. Written inline, one side's
  # "attendee" case ran on a laptop and never on the CI runner, and the
  # 100% branch minimum failed there (2026-09-21). Here both cases run
  # whenever an attendee is compared with a guest, whichever side each is
  # on.
  sig { params(eater: T.any(MealResident, Guest)).returns(Integer) }
  def kind_rank(eater)
    eater.is_a?(Guest) ? 1 : 0
  end

  # Each cook is credited what they spent. On a subsidized meal the eaters
  # were charged less than that, so the cooks share what the eaters were
  # charged, in proportion to what each spent: two cooks who spent $40 and
  # $20 on a meal capped at $18 are credited $12 and $6.
  sig do
    params(meal: Meal, bills: T::Array[Bill], spent: T::Array[Integer], financials: Financials)
      .returns(T::Array[Line])
  end
  def credit_lines(meal, bills, spent, financials)
    credits = credit_units(spent, financials)
    Array.new(bills.size) do |index|
      bill = T.must(bills[index])
      Line.new(
        meal_id: T.must(meal.id),
        resident_id: T.must(bill.resident_id),
        kind: :credit,
        amount: amount(T.must(credits[index])),
        multiplier: nil,
        unit_cost: financials.unit_cost,
        bill_amount: T.must(bill.amount)
      )
    end
  end

  sig { params(spent: T::Array[Integer], financials: Financials).returns(T::Array[Integer]) }
  def credit_units(spent, financials)
    return Array.new(spent.size, 0) if financials.total_multiplier.zero?
    return spent unless subsidized?(financials)

    LargestRemainderSplit.call(financials.effective_units, spent)
  end

  # The effective cost, shared out across the eaters by multiplier. A
  # guest's debit goes to the resident who brought them, which is why a
  # guest line carries a resident_id at all.
  sig do
    params(meal: Meal, people: T::Array[T.any(MealResident, Guest)], financials: Financials).returns(T::Array[Line])
  end
  def debit_lines(meal, people, financials)
    return [] if people.empty?

    shares = if financials.total_multiplier.zero?
               people.map { 0 }
             else
               LargestRemainderSplit.call(financials.effective_units, people.map { |eater| T.must(eater.multiplier) })
             end

    Array.new(people.size) do |index|
      eater = T.must(people[index])
      Line.new(
        meal_id: T.must(meal.id),
        resident_id: T.must(eater.resident_id),
        kind: eater.is_a?(Guest) ? :guest_debit : :debit,
        amount: amount(-T.must(shares[index])),
        multiplier: T.must(eater.multiplier),
        unit_cost: financials.unit_cost,
        bill_amount: nil
      )
    end
  end
end

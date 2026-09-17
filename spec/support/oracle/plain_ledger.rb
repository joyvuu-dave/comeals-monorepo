# frozen_string_literal: true

require 'bigdecimal'

# PlainLedger is a test oracle: a second copy of the cost-splitting
# arithmetic, written from the written rules and from nothing else. The
# comparison specs run it beside the app's ledger and expect the same
# numbers. If the two disagree, either the app or the rules are wrong.
#
# It was written from two documents and nothing else:
#   - CLAUDE.md, "Money Handling Standards" (rules 1 to 11 and "The Money
#     Model")
#   - MODELS.md, "Financial Models" (the flow diagram, "Signs", "The ledger
#     grain"), "MealCharge", "The Multiplier System" and "Where the money
#     math lives"
#
# It does not read the app's code, so it cannot share a misreading with it.
# Never edit this file to make it agree with the app. Fix the rules or the
# app instead.
#
# Assumptions. Each one is a place where the documents are silent or could
# be read two ways, and the reading this file takes.
#
# 1. A bill with no_cost = true is skipped completely: it adds nothing to
#    the meal's cost and gets no credit line. The diagram says
#    "total_cost = sum of bills (no_cost skipped)" and "credit line for
#    each bill". I read "skipped" as skipping the bill, not only its
#    amount, because a cook who spent nothing has nothing to be paid back.
#
# 2. Every other bill, attendee and guest gets a line, even when the
#    amount of the line is zero. The diagram says "for each bill", "for
#    each eater", "for each guest" with no exception. So a meal with eaters
#    and no cost gives every eater a debit line of 0, and a free child
#    (multiplier 0) gets a debit line of 0. A meal whose total multiplier
#    is 0 is written down: every one of its lines is 0 and the lines still
#    exist. To make every line 0 on such a meal, its effective cost is
#    taken as 0 even when it has no cap; "cap * total multiplier" is 0
#    when there is a cap, and the documents say the lines are 0 either way.
#
# 3. "Subsidized" means the effective cost is less than the sum of the
#    bills, that is, cap times total multiplier is strictly less than the
#    total cost. When the two are equal the meal is not subsidized and each
#    cook is credited their bill amount as it is. The numbers come out the
#    same either way, because the two splits give out the same amount.
#
# 4. A cap is a number of dollars per multiplier unit: the documents write
#    "cap * total multiplier". A cap of nil means no cap.
#
# 5. The largest-remainder split compares exact remainders. Every share has
#    the same denominator (the total weight), so the line that "lost the
#    most" in the rounding-down step is the line with the largest
#    remainder of amount * weight divided by total weight. A line with a
#    zero weight has a zero remainder and never gets a leftover unit.
#
# 6. Among cook lines the tie-break is the lowest resident id. The
#    documents say "one credit per cook", so I assume one bill per resident
#    per meal. If a resident somehow has two bills on one meal, the lower
#    bill id comes first, so the result is still deterministic.
#
# 7. At settlement, "the most negative remainders" and "the largest
#    positive remainders" (rule 5) are compared by the fraction each
#    balance lost when it was truncated: the exact balance minus the
#    truncated one. A balance that lost nothing is never touched.
#
# 8. Every amount that comes in must be a whole number of units of 10^-8
#    dollars, and a bill amount or a cap must not be negative. The
#    documents say the columns hold exactly that. An input that breaks
#    this is a bad input, so the oracle raises instead of guessing.
#
# 9. The unit cost a screen shows is not part of any line, so this oracle
#    does not compute it.
module PlainLedger
  # "The ledger grain is 10^-8 dollars" (CLAUDE.md, money rule 4).
  UNITS_PER_DOLLAR = 100_000_000
  GRAIN = BigDecimal('0.00000001')
  CENT = BigDecimal('0.01')

  class Error < StandardError; end

  # A Hash { [meal_id, resident_id] => BigDecimal }: everything one resident
  # was credited and charged on one meal, added up. A pair with no line on
  # the meal is absent.
  def self.net_by_meal(meals)
    nets = Hash.new(0)
    meals.each do |meal|
      lines_for(meal).each do |line|
        nets[[meal.fetch(:id), line.fetch(:resident_id)]] += line.fetch(:units)
      end
    end
    nets.transform_values { |units| dollars(units) }
  end

  # A Hash { resident_id => BigDecimal } with one entry for each id given:
  # the sum of the resident's net amounts across all the meals. A resident
  # with no lines is present at zero.
  #
  # "MealLedger#balances: sum of a resident's lines (at the grain)"
  # (MODELS.md, the flow diagram).
  def self.balances(meals, resident_ids)
    totals = Hash.new(0)
    meals.each do |meal|
      lines_for(meal).each do |line|
        totals[line.fetch(:resident_id)] += line.fetch(:units)
      end
    end
    result = {}
    resident_ids.each { |resident_id| result[resident_id] = dollars(totals[resident_id]) }
    result
  end

  # Given { resident_id => BigDecimal } that sums to exactly zero, the
  # whole-cent amounts { resident_id => BigDecimal } that also sum to
  # exactly zero, by CLAUDE.md money rule 5.
  def self.round_to_cents(raw)
    raw.each_value { |amount| bigdecimal!(amount) }
    check_sums_to_zero(raw, 'balances')

    # "Each balance is first truncated toward zero (a positive balance
    # floors to the cent, a negative one ceils to the cent)" (rule 5).
    # BigDecimal#truncate(2) cuts toward zero at two decimals.
    truncated = raw.transform_values { |amount| amount.truncate(2) }
    fractions = raw.to_h { |resident_id, amount| [resident_id, amount - truncated.fetch(resident_id)] }

    rounded = place_leftover_pennies(truncated, fractions)

    # "It guarantees that rounded balances sum to exactly zero" (rule 5).
    check_sums_to_zero(rounded, 'rounded balances')
    rounded
  end

  # "The truncated amounts then sum to some whole number of cents, positive
  # or negative. If positive, one cent is taken from each of the balances
  # that lost the most on the negative side (the most negative remainders);
  # if negative, one cent is given to each of the balances that lost the
  # most on the positive side (the largest positive remainders)." (rule 5)
  # "Ties are broken by lowest resident_id" (rule 5).
  def self.place_leftover_pennies(truncated, fractions)
    truncated_sum = truncated.values.sum(BigDecimal('0')) / CENT
    raise Error, 'truncated amounts do not sum to a whole number of cents' unless truncated_sum.frac.zero?

    cents = truncated_sum.to_i.abs
    rounded = truncated.dup
    return rounded if cents.zero?

    # +1 gives a cent to positive remainders; -1 takes a cent from negative
    # remainders. Sorting by the remainder times the direction puts "lost
    # the most" first on either side (assumption 7).
    direction = truncated_sum.negative? ? 1 : -1
    candidates = fractions.select { |_, fraction| (fraction * direction).positive? }
    ordered = candidates.keys.sort_by { |resident_id| [-(fractions[resident_id] * direction), resident_id] }
    raise Error, 'not enough remainders to place the leftover cents' if ordered.size < cents

    ordered.first(cents).each { |resident_id| rounded[resident_id] += CENT * direction }
    rounded
  end

  def self.check_sums_to_zero(amounts, what)
    sum = amounts.values.sum(BigDecimal('0'))
    raise Error, "#{what} sum to #{sum.to_s('F')}, not zero" unless sum.zero?
  end

  def self.bigdecimal!(amount)
    raise Error, "#{amount.inspect} is not a BigDecimal" unless amount.is_a?(BigDecimal)

    amount
  end

  # The lines of one meal: [{ resident_id:, units: }, ...], signed. Units
  # are whole numbers of 10^-8 dollars.
  def self.lines_for(meal)
    bills = meal.fetch(:bills).reject { |bill| bill.fetch(:no_cost) } # assumption 1
    attendees = meal.fetch(:attendees)
    guests = meal.fetch(:guests)

    # "A meal's total multiplier is the sum across all attendees and
    # guests" (MODELS.md, The Multiplier System).
    total_multiplier = (attendees + guests).sum { |eater| multiplier_of(eater) }

    # "total_cost = sum of bills (no_cost skipped)" (MODELS.md diagram).
    total_cost = bills.sum { |bill| units_of(bill.fetch(:amount), 'bill amount') }

    # "effective_cost = min(total_cost, cap * total multiplier)".
    # "A meal whose total multiplier is 0 ... has a unit cost of 0, and
    # every one of its lines is 0: each cook is credited 0 and each eater
    # is charged 0. The cook absorbs the cost. The zero lines still exist"
    # (MODELS.md, The Multiplier System). See assumption 2.
    cap = meal.fetch(:cap)
    effective_cost =
      if total_multiplier.zero?
        0
      elsif cap.nil?
        total_cost
      else
        [total_cost, units_of(cap, 'cap') * total_multiplier].min
      end

    credit_lines(bills, total_cost, effective_cost) + debit_lines(attendees, guests, effective_cost)
  end

  # "credit line for each bill: + cook's share of effective_cost".
  # "On a subsidized meal only, the effective cost across the cooks, each
  # weighted by their bill amount. These are the credit lines. On a meal
  # that is not subsidized, each cook's credit is their bill amount as it
  # is." (MODELS.md, The ledger grain)
  def self.credit_lines(bills, total_cost, effective_cost)
    subsidized = effective_cost < total_cost # assumption 3
    # Tie-break among cooks: lowest resident id, then lowest bill id
    # (assumption 6).
    ordered = bills.sort_by { |bill| [bill.fetch(:resident_id), bill.fetch(:id)] }
    weights = ordered.map { |bill| units_of(bill.fetch(:amount), 'bill amount') }
    shares = subsidized ? largest_remainder_split(effective_cost, weights) : weights

    # Signs: "A credit (cooking) is positive" (CLAUDE.md, money rule 11).
    ordered.zip(shares).map { |bill, units| { resident_id: bill.fetch(:resident_id), units: units } }
  end

  # "debit line for each eater: - eater's share of effective_cost, by
  # multiplier" and "guest_debit for each guest: - guest's share of
  # effective_cost, charged to the host" (MODELS.md diagram).
  # "The effective cost across the eaters (attendees and guests), each
  # weighted by their multiplier. These are the debit and guest_debit lines,
  # negated." (MODELS.md, The ledger grain)
  def self.debit_lines(attendees, guests, effective_cost)
    # "Ties go to the lowest resident id. Between an attendee line and a
    # guest line of the same resident, the attendee line comes first.
    # Between two guest lines of the same host, the lower guest id comes
    # first." (MODELS.md, The ledger grain)
    eaters = attendees.map { |a| eater(a.fetch(:resident_id), [a.fetch(:resident_id), 0, a.fetch(:id)], a) } +
             guests.map { |g| eater(g.fetch(:host_id), [g.fetch(:host_id), 1, g.fetch(:id)], g) }
    ordered = eaters.sort_by { |eater| eater.fetch(:key) }
    shares = largest_remainder_split(effective_cost, ordered.map { |eater| eater.fetch(:weight) })

    # Signs: "a debit (eating) is negative" (CLAUDE.md, money rule 11).
    ordered.zip(shares).map { |eater, units| { resident_id: eater.fetch(:resident_id), units: -units } }
  end

  def self.eater(resident_id, key, row)
    { resident_id: resident_id, key: key, weight: multiplier_of(row) }
  end

  # Shares `amount` (whole units) across `weights` (whole numbers) by
  # largest remainder. The weights must already be in tie-break order:
  # when two lines lost the same amount, the earlier one gets the unit.
  #
  # "1. Each line first gets the whole units of its exact share: the amount
  #     times its weight, divided by the total weight, rounded down.
  #  2. The units left over (fewer than there are lines) go one each to the
  #     lines whose exact share lost the most in step 1.
  #  3. Ties go to the lowest resident id. ..." (MODELS.md, The ledger grain)
  def self.largest_remainder_split(amount, weights)
    total_weight = weights.sum
    return split_across_zero_weight(amount, weights) if total_weight.zero?

    # Integer division rounds down for non-negative numbers, and every
    # number here is non-negative.
    shares = weights.map { |weight| (amount * weight) / total_weight }
    remainders = weights.map { |weight| (amount * weight) % total_weight } # assumption 5
    leftover = amount - shares.sum
    raise Error, 'leftover units are not fewer than the lines' unless leftover.between?(0, weights.size - 1)

    # Sort by largest remainder first; among equal remainders, the earlier
    # line (the tie-break order the caller gave) comes first.
    winners = (0...weights.size).sort_by { |i| [-remainders[i], i] }.first(leftover)
    winners.each { |i| shares[i] += 1 }

    raise Error, 'split does not sum to the amount' unless shares.sum == amount

    shares
  end

  # Nothing can be shared out by weight when every weight is zero. That
  # only happens when there is nothing to share, so every share is zero.
  def self.split_across_zero_weight(amount, weights)
    raise Error, "cannot split #{amount} units across weights that sum to zero" unless amount.zero?

    weights.map { 0 }
  end

  # A BigDecimal amount in dollars as a whole number of units of 10^-8
  # dollars. Raises when the amount does not sit on the grain or is
  # negative (assumption 8).
  def self.units_of(amount, what)
    raise Error, "#{what} #{amount.inspect} is not a BigDecimal" unless amount.is_a?(BigDecimal)
    raise Error, "#{what} #{amount.to_s('F')} is negative" if amount.negative?

    scaled = amount * UNITS_PER_DOLLAR
    raise Error, "#{what} #{amount.to_s('F')} is not a whole number of 10^-8 dollars" unless scaled.frac.zero?

    scaled.to_i
  end

  # A whole number of units of 10^-8 dollars as a BigDecimal in dollars.
  # Multiplying by the grain is exact.
  def self.dollars(units)
    BigDecimal(units) * GRAIN
  end

  # An eater's multiplier as a non-negative Integer (assumption 8).
  def self.multiplier_of(eater)
    multiplier = eater.fetch(:multiplier)
    raise Error, "multiplier #{multiplier.inspect} is not an Integer" unless multiplier.is_a?(Integer)
    raise Error, "multiplier #{multiplier} is negative" if multiplier.negative?

    multiplier
  end

  private_class_method :lines_for, :credit_lines, :debit_lines, :eater, :largest_remainder_split,
                       :split_across_zero_weight, :place_leftover_pennies, :check_sums_to_zero,
                       :bigdecimal!, :units_of, :dollars, :multiplier_of
end

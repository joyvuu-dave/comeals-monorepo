# frozen_string_literal: true

require 'bigdecimal'

# PlainLedger is a second copy of the cost-splitting arithmetic, written from
# the rules in CLAUDE.md ("Money Handling Standards") and MODELS.md
# ("Financial Models", "The Multiplier System") and from nothing else. It never
# reads the app's code, so a spec can check the app against it. Every amount is
# a BigDecimal. Nothing rounds except round_to_cents.
#
# Assumptions (the rules are silent; each line is the most literal reading):
# - A cook's share of a capped meal is effective_cost * amount / total_cost.
#   When the cap does not bite, the share is the bill amount itself, so a meal
#   whose bills sum to zero credits each cook zero and divides by nothing.
# - A bill with amount 0 that is not no_cost still makes a credit line (of 0),
#   so the (meal, cook) pair is present with a zero amount.
# - An attendee or guest with multiplier 0 on a meal whose total multiplier is
#   positive still makes a debit line (of 0), so that pair is present too.
# - A meal with eaters but no bills, or only no_cost bills, has total cost 0:
#   every eater gets a debit line of 0 and no cook is credited.
# - A meal whose total multiplier is 0 makes no lines at all, not even a
#   credit: the pairs are absent, and the cooks get nothing.
# - The same resident cooking and eating one meal gets one net amount for the
#   pair: credit plus debit. A host with several guests is charged for each.
# - A cap of exactly cap * total_multiplier == total_cost changes nothing;
#   "the smaller of" is taken with min, so equal values are the same value.
# - BigDecimal division (`/`) keeps its default precision (about 20 significant
#   digits). That is why balances only sum to zero "within 0.000001", and why
#   round_to_cents checks the input sum against that tolerance and raises
#   otherwise.
# - balances returns exactly the ids it was given. A resident with lines who
#   is not in resident_ids is left out; one with no lines is present at 0.
# - In round_to_cents the number of pennies to move is the truncated sum's
#   distance from zero, in cents. The rule guarantees at least that many
#   entries have a remainder of the needed sign, so the ranking never has to
#   touch an entry with a remainder of the wrong sign.
module PlainLedger
  ZERO = BigDecimal('0')
  CENT = BigDecimal('0.01')
  ZERO_SUM_TOLERANCE = BigDecimal('0.000001')

  # Net amount for every (meal, resident) pair that has any line, full precision.
  def self.net_by_meal(meals)
    net = {}
    meals.each do |meal|
      meal_lines(meal).each do |resident_id, amount|
        key = [meal[:id], resident_id]
        net[key] = net.fetch(key, ZERO) + amount
      end
    end
    net
  end

  # One entry per id in resident_ids: the sum of that resident's net amounts.
  def self.balances(meals, resident_ids)
    totals = {}
    resident_ids.each { |resident_id| totals[resident_id] = ZERO }
    net_by_meal(meals).each do |(_meal_id, resident_id), amount|
      totals[resident_id] += amount if totals.key?(resident_id)
    end
    totals
  end

  # Whole-cent amounts that sum to exactly zero, each within one cent of raw.
  def self.round_to_cents(raw)
    raw_sum = raw.values.sum(ZERO)
    raise ArgumentError, "raw balances sum to #{raw_sum}, not zero" if raw_sum.abs > ZERO_SUM_TOLERANCE

    # "first truncate every balance toward zero (a positive balance floors to
    # the cent, a negative one ceils to the cent)"
    cents = raw.transform_values { |amount| amount.truncate(2) }
    remainders = raw.to_h { |resident_id, amount| [resident_id, amount - cents[resident_id]] }
    shortfall = ZERO - cents.values.sum(ZERO)
    hand_out_pennies(cents, remainders, shortfall)
    raise "rounded balances sum to #{cents.values.sum(ZERO)}, not zero" unless cents.values.sum(ZERO).zero?

    cents
  end

  # Every credit, debit, and guest debit of one meal as [resident_id, amount].
  def self.meal_lines(meal)
    # "A no_cost bill makes no line at all"
    cooks = meal[:bills].reject { |bill| bill[:no_cost] }
    # "Each guest is debited ... charged to the guest's host"
    eaters = meal[:attendees].map { |row| [row[:resident_id], row[:multiplier]] } +
             meal[:guests].map { |row| [row[:host_id], row[:multiplier]] }
    # "The total multiplier is the sum of every attendee's multiplier plus every guest's multiplier"
    total_multiplier = eaters.sum { |_resident_id, multiplier| multiplier }
    # "A meal where nobody can be charged ... has unit cost 0 and makes no lines"
    return [] if total_multiplier.zero?

    # "A meal's total cost is the sum of its bills, skipping bills marked no_cost"
    total_cost = cooks.sum(ZERO) { |bill| bill[:amount] }
    effective_cost = effective(total_cost, meal[:cap], total_multiplier)
    # "Unit cost = effective cost / total multiplier"
    unit_cost = effective_cost / BigDecimal(total_multiplier)

    # "Each cook ... is credited their share of the effective cost" (positive)
    credits = cooks.map { |bill| [bill[:resident_id], cook_share(bill[:amount], total_cost, effective_cost)] }
    # "Each attendee is debited unit cost x their multiplier" (negative)
    debits = eaters.map { |resident_id, multiplier| [resident_id, ZERO - (unit_cost * multiplier)] }
    credits + debits
  end

  # "Effective cost = the smaller of total cost and cap x total multiplier
  # (no cap means effective cost = total cost)"
  def self.effective(total_cost, cap, total_multiplier)
    return total_cost if cap.nil?

    [total_cost, cap * total_multiplier].min
  end

  # "in proportion to what they spent. With no cap, that is simply their bill amount."
  def self.cook_share(amount, total_cost, effective_cost)
    return amount if effective_cost == total_cost

    effective_cost * amount / total_cost
  end

  # Move the leftover pennies. shortfall > 0: the truncated amounts sum too
  # low, so "add pennies to the largest positive remainders". shortfall < 0:
  # they sum too high, so "subtract pennies from the most negative remainders".
  # "Ties go to the lowest resident id."
  def self.hand_out_pennies(cents, remainders, shortfall)
    pennies = (shortfall.abs / CENT).to_i
    ranked = if shortfall.positive?
               remainders.keys.sort_by { |resident_id| [ZERO - remainders[resident_id], resident_id] }
             else
               remainders.keys.sort_by { |resident_id| [remainders[resident_id], resident_id] }
             end
    step = shortfall.positive? ? CENT : ZERO - CENT
    ranked.first(pennies).each { |resident_id| cents[resident_id] += step }
  end

  private_class_method :meal_lines, :effective, :cook_share, :hand_out_pennies
end

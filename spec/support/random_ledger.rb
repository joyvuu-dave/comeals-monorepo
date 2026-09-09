# frozen_string_literal: true

# Random ledgers, built in memory with no database, for the property spec
# (settlement_allocate_to_cents_on_random_ledgers_spec.rb) and the oracle
# comparison (meal_ledger_against_plain_ledger_spec.rb). Each ledger comes
# from a seed, so a failing case can be rerun alone. The order of the random
# draws is part of the contract: change it and every seed means a different
# ledger.
module RandomLedger
  RESIDENTS = (1..30).to_a

  # cents_max: the largest bill, in cents. The property spec uses receipts
  # up to $9,999.99; the oracle comparison also runs small receipts, where
  # sub-dollar balances and ties are common.
  def self.meal(rng, index, cents_max: 999_999)
    meal = Meal.new(id: index, date: Date.new(2026, 4, 1) + index)
    meal.cap = rng.rand < 0.4 ? BigDecimal(format('%.2f', rng.rand(1.0..30.0))) : nil

    resident_multipliers = [0, 1, 2]
    guest_multipliers = [1, 2]
    eaters = RESIDENTS.sample(rng.rand(0..12), random: rng)
    eaters.each do |id|
      meal.meal_residents.build(resident_id: id, multiplier: resident_multipliers.sample(random: rng))
    end
    rng.rand(0..4).times do
      meal.guests.build(resident_id: RESIDENTS.sample(random: rng), multiplier: guest_multipliers.sample(random: rng))
    end

    # Cooks may also eat (cook ids drawn from everyone, eaters included).
    RESIDENTS.sample(rng.rand(0..3), random: rng).each do |id|
      no_cost = rng.rand < 0.15
      amount = no_cost ? BigDecimal('0') : BigDecimal(rng.rand(0..cents_max)) / 100
      meal.bills.build(resident_id: id, amount: amount, no_cost: no_cost)
    end
    meal
  end

  def self.meals(seed, cents_max: 999_999)
    rng = Random.new(seed)
    Array.new(rng.rand(1..40)) { |i| meal(rng, i + 1, cents_max: cents_max) }
  end

  # The same meal as plain hashes, the shape the oracle reads.
  def self.plain(meal)
    {
      id: meal.id,
      cap: meal.cap,
      bills: meal.bills.map { |b| { resident_id: b.resident_id, amount: b.amount, no_cost: b.no_cost } },
      attendees: meal.meal_residents.map { |a| { resident_id: a.resident_id, multiplier: a.multiplier } },
      guests: meal.guests.map { |g| { host_id: g.resident_id, multiplier: g.multiplier } }
    }
  end
end

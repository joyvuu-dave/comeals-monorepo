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
    # Rows built in memory get ids the way saved rows would, counting up
    # in the order they are made: the ledger breaks a tie between two
    # guests of one host by guest id, so a row must have one.
    eaters = RESIDENTS.sample(rng.rand(0..12), random: rng)
    eaters.each_with_index do |id, row|
      meal.meal_residents.build(id: (index * 100) + row + 1, resident_id: id,
                                multiplier: resident_multipliers.sample(random: rng))
    end
    rng.rand(0..4).times do |row|
      meal.guests.build(id: (index * 100) + row + 1, resident_id: RESIDENTS.sample(random: rng),
                        multiplier: guest_multipliers.sample(random: rng))
    end

    # Cooks may also eat (cook ids drawn from everyone, eaters included).
    RESIDENTS.sample(rng.rand(0..3), random: rng).each_with_index do |id, row|
      no_cost = rng.rand < 0.15
      amount = no_cost ? no_cost_amount(rng, index, row, cents_max) : BigDecimal(rng.rand(0..cents_max)) / 100
      meal.bills.build(id: (index * 100) + row + 1, resident_id: id, amount: amount, no_cost: no_cost)
    end
    # The rows built above are all there are. Without this, Rails reads
    # an association on a new meal that has an id with a query for more
    # rows, one per meal, which prosopite reports as an N+1 in the ledger.
    %i[meal_residents guests bills].each { |name| meal.association(name).loaded! }
    meal
  end

  # A no-cost bill keeps an amount, as a real one can (the API saves both
  # fields), so the no-cost rule has to be what leaves it out. With a $0
  # amount the ledger came out the same whether or not no_cost was
  # honored. The amount comes from a generator of its own, seeded from the
  # ledger's seed and the bill's place, so the draws above, and so every
  # seed's ledger, are what they were before (2026-09-28).
  def self.no_cost_amount(rng, index, row, cents_max)
    BigDecimal(Random.new((rng.seed * 100_000) + (index * 10) + row).rand(0..cents_max)) / 100
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
      bills: meal.bills.map { |b| { id: b.id, resident_id: b.resident_id, amount: b.amount, no_cost: b.no_cost } },
      attendees: meal.meal_residents.map { |a| { id: a.id, resident_id: a.resident_id, multiplier: a.multiplier } },
      guests: meal.guests.map { |g| { id: g.id, host_id: g.resident_id, multiplier: g.multiplier } }
    }
  end
end

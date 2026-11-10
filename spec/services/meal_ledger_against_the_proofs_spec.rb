# frozen_string_literal: true

require 'rails_helper'

# The lines of a dinner against the Python made from the proofs (issue
# #269, step 6; spec/support/proven.rb). Each meal's rows go to both, in
# the order the meal holds them, and the spec fails on any line that
# differs. Only one set of lines follows the rules
# (proofs/MealLines.dfy, OnlyOneSetOfLines), and the proofs put the cooks
# and the eaters in tie-break order themselves (proofs/TieOrder.dfy), so
# a match means MealLedger gives the proven lines for that meal.
#
# It runs the random ledgers of the property specs
# (spec/support/random_ledger.rb), and every small dinner built from a
# few rows that test the tie-break order: two guests of one host, given
# with the higher guest id first, that host as an attendee after them,
# and a resident with a lower id last.
#
# MONEY_SWEEP=full runs more small dinners; MONEY_PROPERTY_SEEDS and
# MONEY_PROPERTY_SEED change the seeds (spec/support/property_seeds.rb).
RSpec.describe MealLedger do
  describe 'against the Python made from the proofs' do
    def path = 'spec/services/meal_ledger_against_the_proofs_spec.rb'

    # meals: [label, meal]
    def compare(meals)
      failures = MoneySweep::Failures.new
      by_meal = described_class.new(meals.map(&:last)).lines.group_by(&:meal_id)
      answers = Proven.answers(meals.map { |_, meal| Proven.dinner_request(meal) })
      meals.zip(answers).each do |(label, meal), answer|
        ruby = Proven.ledger_lines(by_meal.fetch(meal.id, []))
        proven = answer['refused'] ? :refused : Proven.dinner_lines(answer)
        failures.add("#{label}, meal #{meal.id}: Ruby #{ruby}, proofs #{proven}") unless ruby == proven
      end
      failures
    end

    it 'gives the proven lines on the meals of random ledgers' do
      meals = PropertySeeds.seeds(default: 100).flat_map do |seed|
        label = "seed #{seed} (#{PropertySeeds.rerun_command(seed, path)})"
        RandomLedger.meals(seed).map { |meal| [label, meal] } +
          RandomLedger.meals(seed, cents_max: 500).map { |meal| ["#{label}, small receipts", meal] }
      end

      # Meal ids repeat across seeds, so each seed's meals get their own.
      meals.each_with_index { |(_, meal), index| meal.id = index + 1 }
      failures = compare(meals)

      expect(failures.count).to eq(0), failures.to_s
    end

    def unit = MealLedger::UNIT

    # The eaters, in the order the meal holds them: [kind, resident id,
    # row id, the multipliers it may have]. A guest is never free.
    def eaters
      [
        [:guest, 2, 9, [1, 2]],
        [:guest, 2, 4, [1, 2]],
        [:attendee, 2, 30, [0, 1, 2]],
        [:attendee, 1, 31, [0, 1, 2]]
      ]
    end

    # Each cook is absent, spent a few units, or marked No cost with an
    # amount on it (which the rules leave out whatever it holds).
    def cook_choices(size) = [nil, 1, 2, :no_cost] + { small: [], full: [3, 100_000_001] }.fetch(size)
    def caps(size) = [nil, 1] + { small: [], full: [2] }.fetch(size)
    def cancelled(size) = { small: [false], full: [false, true] }.fetch(size)

    def dinner(id, rows, cooks, cap, cancelled)
      meal = Meal.new(id: id, date: Date.new(2026, 4, 1), cap: cap && (unit * cap))
      meal.cancelled_at = Time.utc(2026, 4, 1) if cancelled
      rows.each do |(kind, resident_id, row_id, _), multiplier|
        next if multiplier.nil?

        rows = kind == :guest ? meal.guests : meal.meal_residents
        rows.build(id: row_id, resident_id: resident_id, multiplier: multiplier)
      end
      cooks.each_with_index do |(resident_id, choice), row|
        next if choice.nil?

        no_cost = choice == :no_cost
        meal.bills.build(id: row + 1, resident_id: resident_id, amount: unit * (no_cost ? 5 : choice), no_cost: no_cost)
      end
      %i[meal_residents guests bills].each { |name| meal.association(name).loaded! }
      meal
    end

    it 'gives the proven lines on every small dinner' do
      size = MoneySweep.size
      eater_choices = eaters.map { |eater| [nil, *eater.last] }
      meals = []
      eater_choices.first.product(*eater_choices.drop(1)) do |multipliers|
        cook_choices(size).product(cook_choices(size)) do |choices|
          caps(size).product(cancelled(size)) do |cap, cancelled|
            meal = dinner(meals.size + 1, eaters.zip(multipliers), [3, 1].zip(choices), cap, cancelled)
            meals << [multipliers.inspect, meal]
          end
        end
      end

      failures = compare(meals)

      expect(failures.count).to eq(0), failures.to_s
      expect(meals.size).to be >= 4608
    end
  end
end

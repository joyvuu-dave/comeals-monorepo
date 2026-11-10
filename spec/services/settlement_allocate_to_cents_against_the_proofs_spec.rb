# frozen_string_literal: true

require 'rails_helper'

# The cent rounding against the Python made from the proofs (issue #269,
# step 6; spec/support/proven.rb). It runs the inputs of the step 1 sweep
# (spec/support/money_sweep.rb) and the balances of the property spec's
# random ledgers (spec/support/random_ledger.rb) through both, and fails
# on any answer that differs. Only one rounding follows the rule
# (proofs/CentRounding.dfy, OnlyOneRounding), and the proofs put the
# balances in order of id themselves (proofs/TieOrder.dfy), so a match
# means the Ruby gives the proven answer on that input.
#
# MONEY_SWEEP=full runs the full sweep; MONEY_PROPERTY_SEEDS and
# MONEY_PROPERTY_SEED change the seeds (spec/support/property_seeds.rb).
RSpec.describe Settlement do
  describe 'allocate_to_cents against the Python made from the proofs' do
    def ruby_answer(exact)
      raw = exact.transform_values { |units| MealLedger::UNIT * units }
      described_class.allocate_to_cents(raw, reconciliation_id: 'proofs')
                     .transform_values { |amount| Proven.units(amount) }
    rescue RuntimeError
      :refused
    end

    # inputs: [label, { id => units }]
    def compare(inputs)
      failures = MoneySweep::Failures.new
      answers = Proven.answers(inputs.map { |_, exact| { round: [MoneySweep::CENT, exact.to_a] } })
      inputs.zip(answers).each do |(label, exact), answer|
        ruby = ruby_answer(exact)
        proven = answer['refused'] ? :refused : answer.fetch('balances').to_h
        failures.add("#{label} #{exact}: Ruby #{ruby.inspect}, proofs #{proven.inspect}") unless ruby == proven
      end
      failures
    end

    it 'gives the proven rounding on every input of the sweep' do
      inputs = MoneySweep.each_rounding(MoneySweep.size).map { |exact| ['sweep', exact] }

      failures = compare(inputs)

      expect(failures.count).to eq(0), failures.to_s
      expect(inputs.size).to be >= 1640
    end

    it 'gives the proven rounding on the balances of random ledgers' do
      path = 'spec/services/settlement_allocate_to_cents_against_the_proofs_spec.rb'
      inputs = PropertySeeds.seeds(default: 100).map do |seed|
        raw = MealLedger.new(RandomLedger.meals(seed)).balances(RandomLedger::RESIDENTS)
        label = "seed #{seed} (#{PropertySeeds.rerun_command(seed, path)})"
        [label, raw.transform_values { |amount| Proven.units(amount) }]
      end

      failures = compare(inputs)

      expect(failures.count).to eq(0), failures.to_s
    end

    it 'refuses balances that do not sum to zero, as the proofs do' do
      inputs = [['one unit over', { 10 => 1 }], ['a cent each way and one over', { 10 => 1_000_000, 20 => -999_999 }]]

      failures = compare(inputs)

      expect(failures.count).to eq(0), failures.to_s
      expect(inputs.map { |_, exact| ruby_answer(exact) }).to all(eq(:refused))
    end
  end
end

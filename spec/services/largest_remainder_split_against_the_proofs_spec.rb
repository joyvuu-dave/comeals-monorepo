# frozen_string_literal: true

require 'rails_helper'

# The split against the Python made from the proofs (issue #269, step 6;
# spec/support/proven.rb). It runs the inputs of the step 1 sweep
# (spec/support/money_sweep.rb) through both and fails on any answer that
# differs. Only one list of shares follows the rule
# (proofs/LargestRemainderSplit.dfy, OnlyOneSplit), so a match means the
# Ruby gives the proven answer on that input.
#
# MONEY_SWEEP=full runs the full size.
RSpec.describe LargestRemainderSplit do
  describe 'against the Python made from the proofs' do
    def ruby_answer(total, weights)
      described_class.call(total, weights)
    rescue ArgumentError
      :refused
    end

    def compare(inputs)
      failures = MoneySweep::Failures.new
      answers = Proven.answers(inputs.map { |total, weights| { split: [total, weights] } })
      inputs.zip(answers).each do |(total, weights), answer|
        ruby = ruby_answer(total, weights)
        proven = answer['refused'] ? :refused : answer.fetch('shares')
        failures.add("call(#{total}, #{weights}): Ruby #{ruby.inspect}, proofs #{proven.inspect}") unless ruby == proven
      end
      failures
    end

    it 'gives the proven shares on every input of the sweep' do
      size = MoneySweep.size
      inputs = MoneySweep.each_split(size).to_a + MoneySweep.each_large_split(size).to_a

      failures = compare(inputs)

      expect(failures.count).to eq(0), failures.to_s
      expect(inputs.size).to be > 10_000
    end

    it 'refuses what the proofs refuse' do
      inputs = MoneySweep.split_lengths(MoneySweep.size).map { |length| [5, Array.new(length, 0)] } +
               [[5, []], [-1, [1, 2]], [5, [1, -1, 2]], [0, [0]]]

      failures = compare(inputs)

      expect(failures.count).to eq(0), failures.to_s
      expect(inputs.map { |total, weights| ruby_answer(total, weights) }).to all(eq(:refused))
    end
  end
end

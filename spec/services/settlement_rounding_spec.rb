# frozen_string_literal: true

require 'rails_helper'

# The rounding rule, pinned one case at a time (CLAUDE.md, money rule 5:
# truncate toward zero, then hand the leftover pennies to the largest
# remainders, ties to the lowest resident id).
#
# The property spec next to this file checks what must hold for any
# ledger: the result sums to zero, is whole cents, and is within a cent
# of the exact amount. Other rules satisfy that too, such as handing the
# pennies out by resident id, or rounding half up. Mutant made both of
# those changes and no spec failed (docs/mutation-testing.md,
# 2026-09-08). These examples say which resident gets each penny.
RSpec.describe Settlement do
  describe 'rounding to cents' do
    def cents(value) = BigDecimal(value)

    def round(raw)
      described_class.allocate_to_cents(raw.transform_values { |value| BigDecimal(value) }, reconciliation_id: 'spec')
    end

    it 'truncates toward zero, and awards nothing when the truncated amounts already balance' do
      expect(round(1 => '0.567', 2 => '-0.567')).to eq(1 => cents('0.56'), 2 => cents('-0.56'))
    end

    it 'gives a missing penny to the largest positive remainder, not to the lowest id' do
      expect(round(1 => '0.992', 2 => '0.998', 3 => '-1.99'))
        .to eq(1 => cents('0.99'), 2 => cents('1.00'), 3 => cents('-1.99'))
    end

    it 'takes an extra penny from the largest negative remainder, not from the lowest id' do
      expect(round(1 => '1.99', 2 => '-0.992', 3 => '-0.998'))
        .to eq(1 => cents('1.99'), 2 => cents('-0.99'), 3 => cents('-1.00'))
    end

    it 'breaks a tie by the lowest resident id, whatever order the balances came in' do
      expect(round(2 => '0.995', 1 => '0.995', 3 => '-1.99'))
        .to eq(1 => cents('1.00'), 2 => cents('0.99'), 3 => cents('-1.99'))
      expect(round(3 => '-0.995', 2 => '-0.995', 1 => '1.99'))
        .to eq(1 => cents('1.99'), 2 => cents('-1.00'), 3 => cents('-0.99'))
    end

    it 'hands out several pennies in remainder order' do
      expect(round(1 => '0.996', 2 => '0.997', 3 => '0.998', 4 => '-2.991'))
        .to eq(1 => cents('0.99'), 2 => cents('1.00'), 3 => cents('1.00'), 4 => cents('-2.99'))
    end
  end
end

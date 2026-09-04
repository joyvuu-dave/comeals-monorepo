# frozen_string_literal: true

require 'rails_helper'

# The sigs on Settlement are checked when the code runs, in this suite and
# in production (docs/sorbet.md, "Runtime behaviour"). This pins that the
# checks are on at the edges a caller can get wrong. Runtime type checks only.
RSpec.describe Settlement do
  it 'refuses a cutoff that is not a Date' do
    expect { described_class.preview(cutoff: '2026-01-01') }.to raise_error(TypeError, /cutoff/)
  end

  it 'refuses a preview whose balances are not keyed by resident id' do
    expect do
      described_class::Preview.new(cutoff: Date.new(2026, 1, 1), meals: [], ledger: MealLedger.new([]),
                                   resident_balances: 'none', skipped_meals: [])
    end.to raise_error(TypeError, /resident_balances/)
  end

  it 'refuses to settle anything but a Reconciliation' do
    expect { described_class.new(Meal.new) }.to raise_error(TypeError, /reconciliation/)
  end
end

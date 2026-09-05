# frozen_string_literal: true

require 'rails_helper'

# The sigs on RetryOnConflict, SettleAndNotify and MealCostSummary are
# checked when the code runs, in this suite and in production
# (docs/sorbet.md, "Runtime behaviour"). Runtime type checks only.
RSpec.describe RetryOnConflict do
  it 'refuses a retry with no block to run' do
    expect { described_class.call }.to raise_error(TypeError, /blk/)
  end

  it 'refuses to settle with a cutoff that is not a Date' do
    expect { SettleAndNotify.call(cutoff: '2026-01-01') }.to raise_error(TypeError, /cutoff/)
  end

  it 'refuses a cost summary for anything but a Meal' do
    expect { MealCostSummary.for(Bill.new) }.to raise_error(TypeError, /meal/)
  end
end

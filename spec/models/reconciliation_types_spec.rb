# frozen_string_literal: true

require 'rails_helper'

# The sigs on Reconciliation are checked when the code runs, in this suite
# and in production (docs/sorbet.md, "Runtime behaviour"). Runtime type
# checks only.
RSpec.describe Reconciliation do
  it 'refuses to settle balances from anything but a MealLedger' do
    expect { described_class.new.settlement_balances([]) }.to raise_error(TypeError, /ledger/)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The sigs on Meal and Resident are checked when the code runs, in this
# suite and in production (docs/sorbet.md, "Runtime behaviour"). Runtime
# type checks only.
RSpec.describe Meal do
  it 'refuses a holiday check on anything but a Date' do
    expect { described_class.is_holiday?(Time.zone.now) }.to raise_error(TypeError, /date/)
  end

  it 'refuses a unit cost for the balance oracle from anything but a Meal' do
    expect { Resident.new.oracle_unit_cost(Bill.new) }.to raise_error(TypeError, /meal/)
  end
end

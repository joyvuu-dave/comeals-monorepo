# frozen_string_literal: true

require 'rails_helper'

# The sigs on Meal are checked when the code runs, in this
# suite and in production (docs/sorbet.md, "Runtime behaviour"). Runtime
# type checks only.
RSpec.describe Meal do
  it 'refuses a holiday check on anything but a Date' do
    expect { described_class.is_holiday?(Time.zone.now) }.to raise_error(TypeError, /date/)
  end
end

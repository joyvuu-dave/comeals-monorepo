# frozen_string_literal: true

require 'rails_helper'

# The sigs on Holidays are checked when the code runs, in this suite and
# in production (docs/sorbet.md, "Runtime behaviour"). Runtime type
# checks only.
RSpec.describe Holidays do
  it 'refuses a holiday check on anything but a Date' do
    expect { described_class.holiday?(Time.zone.now) }.to raise_error(TypeError, /date/)
  end
end

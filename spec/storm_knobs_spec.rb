# frozen_string_literal: true

require 'rails_helper'

# The storm's settings (spec/support/storm/knobs.rb) are read the way the
# seed settings are (SeedSettings): digits only, in base 10.
RSpec.describe Storm do
  describe '.knob' do
    def knob(name, default, env) = described_class.knob(name, default, env: env)

    it 'gives the default when the setting is not there' do
      expect(knob(:clients, 24, {})).to eq(24)
    end

    it 'reads a leading zero as base 10, as a person reads it' do
      expect(knob(:seed, 1, { 'STORM_SEED' => '010' })).to eq(10)
    end

    it 'takes seed 0' do
      expect(knob(:seed, 1, { 'STORM_SEED' => '0' })).to eq(0)
    end

    ['1_000', ' 10', '0x10', '2.5', 'many', ''].each do |value|
      it "refuses STORM_SECONDS=#{value.inspect}" do
        expect { knob(:seconds, 15, { 'STORM_SECONDS' => value }) }
          .to raise_error(ArgumentError, /\ASTORM_SECONDS must be a whole number/)
      end
    end
  end
end

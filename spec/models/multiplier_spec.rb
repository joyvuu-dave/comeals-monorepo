# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Multiplier do
  it 'defines the three price bands' do
    expect(Multiplier::FREE).to eq(0)
    expect(Multiplier::HALF).to eq(1)
    expect(Multiplier::FULL).to eq(2)
  end

  describe '.band_name' do
    it 'names the three bands' do
      expect(described_class.band_name(Multiplier::FREE)).to eq('free')
      expect(described_class.band_name(Multiplier::HALF)).to eq('half price')
      expect(described_class.band_name(Multiplier::FULL)).to eq('full price')
    end

    it 'names an out-of-band value by its number' do
      expect(described_class.band_name(3)).to eq('3')
    end
  end

  # A schema default cannot reference a Ruby constant, so the database
  # writes these as the literal 2. This is what keeps them from drifting
  # away from Multiplier::FULL.
  describe 'database column defaults' do
    it 'pins residents.multiplier to FULL' do
      expect(Resident.column_defaults.fetch('multiplier')).to eq(Multiplier::FULL)
    end

    it 'pins guests.multiplier to FULL' do
      expect(Guest.column_defaults.fetch('multiplier')).to eq(Multiplier::FULL)
    end
  end

  # The ledger's ignorance of what a multiplier means is the design: it
  # sums multipliers into a divisor and never asks what a value of 2 means.
  # Pricing policy must not leak into it (see the module comment).
  it 'is not referenced by MealLedger' do
    source = Rails.root.join('app/services/meal_ledger.rb').read
    code_lines = source.lines.reject { |line| line.strip.start_with?('#') }
    expect(code_lines.join).not_to match(/\bMultiplier\b/)
  end
end

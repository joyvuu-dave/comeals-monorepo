# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Holidays do
  describe '.holiday?' do
    it 'detects Thanksgiving (4th Thursday in November)' do
      expect(described_class.holiday?(Date.new(2026, 11, 26))).to be true
      expect(described_class.holiday?(Date.new(2025, 11, 27))).to be true
    end

    it 'does not take the third Thursday, or a Wednesday in the fourth week, for Thanksgiving' do
      expect(described_class.holiday?(Date.new(2026, 11, 19))).to be false
      expect(described_class.holiday?(Date.new(2026, 11, 25))).to be false
    end

    it 'detects Christmas' do
      expect(described_class.holiday?(Date.new(2026, 12, 25))).to be true
    end

    it 'detects New Year' do
      expect(described_class.holiday?(Date.new(2026, 1, 1))).to be true
    end

    it 'detects Mother\'s Day (2nd Sunday in May)' do
      expect(described_class.holiday?(Date.new(2026, 5, 10))).to be true
      expect(described_class.holiday?(Date.new(2025, 5, 11))).to be true
    end

    it 'does not take the first Sunday, or a Monday in the second week, for Mother\'s Day' do
      expect(described_class.holiday?(Date.new(2026, 5, 3))).to be false
      expect(described_class.holiday?(Date.new(2026, 5, 11))).to be false
    end

    it 'detects Easter' do
      # Easter 2026 is April 5
      expect(described_class.holiday?(Date.new(2026, 4, 5))).to be true
      # Easter 2025 is April 20
      expect(described_class.holiday?(Date.new(2025, 4, 20))).to be true
      # A March Easter: 2024 was March 31
      expect(described_class.holiday?(Date.new(2024, 3, 31))).to be true
    end

    it 'detects July 4th' do
      expect(described_class.holiday?(Date.new(2026, 7, 4))).to be true
    end

    it 'returns false for non-holidays' do
      expect(described_class.holiday?(Date.new(2026, 3, 15))).to be false
      expect(described_class.holiday?(Date.new(2026, 8, 20))).to be false
    end
  end
end

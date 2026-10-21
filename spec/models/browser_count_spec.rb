# frozen_string_literal: true

require 'rails_helper'

# One row per day and kind of browser: how many page loads it had, and
# whether the browser check passed. Counts only: no IP, no resident, no
# User-Agent string.
RSpec.describe BrowserCount do
  let(:key) do
    { date: Date.new(2026, 10, 21), browser: 'Safari', major: 18, os: 'iOS', device: 'phone', result: 'passed' }
  end

  describe '.add_one!' do
    it 'starts a count at one' do
      described_class.add_one!(**key)

      expect(described_class.sole).to have_attributes(**key, count: 1)
    end

    it 'adds to the count of the same day and browser' do
      3.times { described_class.add_one!(**key) }

      expect(described_class.sole.count).to eq(3)
    end

    it 'keeps a count per day, browser, version, system, device and result' do
      described_class.add_one!(**key)
      [{ date: Date.new(2026, 10, 22) }, { browser: 'Chrome' }, { major: 17 }, { os: 'iPadOS' },
       { device: 'tablet' }, { result: 'failed' }].each do |change|
        described_class.add_one!(**key, **change)
      end

      expect(described_class.count).to eq(7)
      expect(described_class.pluck(:count)).to all(eq(1))
    end

    # A browser whose version could not be read has no version, and its
    # page loads still add up in one row, not one row each.
    it 'adds up the page loads of a browser with no version in one row' do
      2.times { described_class.add_one!(**key, browser: 'Unknown', major: nil) }

      expect(described_class.sole).to have_attributes(major: nil, count: 2)
    end
  end

  describe 'validations' do
    subject(:browser_count) { described_class.new(**key, count: 1) }

    it { is_expected.to be_valid }

    it 'needs a date, a browser and a system' do
      %i[date browser os].each do |attribute|
        expect(described_class.new(**key, count: 1, attribute => nil)).not_to be_valid
      end
    end

    it 'takes only the four kinds of device' do
      expect(described_class.new(**key, count: 1, device: 'watch')).not_to be_valid
    end

    it 'takes only the three results of the check' do
      expect(described_class.new(**key, count: 1, result: 'maybe')).not_to be_valid
    end

    it 'counts at least one page load' do
      expect(described_class.new(**key, count: 0)).not_to be_valid
    end

    it 'takes a version above zero, or none' do
      expect(described_class.new(**key, count: 1, major: 0)).not_to be_valid
      expect(described_class.new(**key, count: 1, major: nil)).to be_valid
    end

    it 'takes a browser and a system name of at most 60 characters' do
      expect(described_class.new(**key, count: 1, browser: 'x' * 61)).not_to be_valid
      expect(described_class.new(**key, count: 1, os: 'x' * 61)).not_to be_valid
    end
  end

  # The admin page (app/admin/browsers.rb) shows the page loads by month.
  describe '.by_month' do
    it 'adds up each kind of browser over each month, newest month first, most page loads first' do
      2.times { described_class.add_one!(**key, date: Date.new(2026, 9, 30)) }
      described_class.add_one!(**key, date: Date.new(2026, 10, 1))
      described_class.add_one!(**key, date: Date.new(2026, 10, 2))
      3.times { described_class.add_one!(**key, date: Date.new(2026, 10, 2), browser: 'Chrome', major: 141) }

      rows = described_class.by_month.map do |row|
        [row.month, row.browser, row.major, row.os, row.device, row.result, row.loads]
      end

      expect(rows).to eq([
                           [Date.new(2026, 10, 1), 'Chrome', 141, 'iOS', 'phone', 'passed', 3],
                           [Date.new(2026, 10, 1), 'Safari', 18, 'iOS', 'phone', 'passed', 2],
                           [Date.new(2026, 9, 1), 'Safari', 18, 'iOS', 'phone', 'passed', 2]
                         ])
    end
  end
end

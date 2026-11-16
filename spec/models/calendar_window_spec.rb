# frozen_string_literal: true

require 'rails_helper'

# The days a new dinner, event or booking may fall on (challenge 6).
# Each model's own rule, and each way in, are in
# spec/models/calendar_window_validator_spec.rb and
# spec/requests/calendar_window_entry_points_spec.rb.
RSpec.describe CalendarWindow do
  def days(today)
    described_class.days(Date.new(*today))
  end

  it 'goes from 10 years before today to 10 years after, both ends included' do
    expect(days([2026, 11, 15])).to eq(Date.new(2016, 11, 15)..Date.new(2036, 11, 15))
  end

  it 'moves with today, so it never runs out' do
    expect(days([3026, 11, 15])).to eq(Date.new(3016, 11, 15)..Date.new(3036, 11, 15))
  end

  it 'counts 10 years from February 29 to February 28 at both ends' do
    expect(days([2028, 2, 29])).to eq(Date.new(2018, 2, 28)..Date.new(2038, 2, 28))
  end

  it 'counts across 2100, a year that divides by 4 and has no February 29' do
    expect(days([2096, 2, 29])).to eq(Date.new(2086, 2, 28)..Date.new(2106, 2, 28))
  end

  it 'never goes past December 31, 9999, the last day with a 4-digit year' do
    expect(days([9989, 12, 31]).last).to eq(Date.new(9999, 12, 31))
    expect(days([9990, 1, 1]).last).to eq(Date.new(9999, 12, 31))
    expect(days([9999, 12, 31])).to eq(Date.new(9989, 12, 31)..Date.new(9999, 12, 31))
  end

  describe '.cover?' do
    let(:today) { Date.new(2026, 11, 15) }

    it 'takes each end and refuses the day past it' do
      expect(described_class.cover?(Date.new(2016, 11, 15), today: today)).to be(true)
      expect(described_class.cover?(Date.new(2016, 11, 14), today: today)).to be(false)
      expect(described_class.cover?(Date.new(2036, 11, 15), today: today)).to be(true)
      expect(described_class.cover?(Date.new(2036, 11, 16), today: today)).to be(false)
    end

    it 'refuses the year 10000' do
      expect(described_class.cover?(Date.new(10_000, 1, 1), today: Date.new(9999, 12, 31))).to be(false)
    end
  end
end

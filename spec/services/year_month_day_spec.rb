# frozen_string_literal: true

require 'rails_helper'

# A day sent in a request must be written exactly as YYYY-MM-DD, the one
# form public/api.md gives. Date.parse and Date.iso8601 take more than
# that, and some of what they take has no year or no month, which they
# fill in from the machine's own clock.
RSpec.describe YearMonthDay do
  describe '.parse' do
    def expect_refused(texts)
      texts.each do |text|
        expect { described_class.parse(text) }.to raise_error(Date::Error), "for #{text.inspect}"
      end
    end

    it 'reads a day written as YYYY-MM-DD' do
      expect(described_class.parse('2026-10-16')).to eq(Date.new(2026, 10, 16))
      expect(described_class.parse('2024-02-29')).to eq(Date.new(2024, 2, 29))
      expect(described_class.parse('1999-12-31')).to eq(Date.new(1999, 12, 31))
    end

    # ActiveSupport::SafeBuffer is a String too.
    it 'reads any kind of String' do
      expect(described_class.parse(ActiveSupport::SafeBuffer.new('2026-10-16'))).to eq(Date.new(2026, 10, 16))
    end

    it 'refuses a day with no year, no month or no day, which a looser parser fills in', :aggregate_failures do
      expect_refused(%w[--10-12 12 2026-10 Sunday October])
    end

    it 'refuses the other forms Date.iso8601 takes', :aggregate_failures do
      expect_refused(%w[2026-285 2026-W42-5 20261016 2026-10-16T05:00 +2026-10-16])
    end

    it 'refuses a day that does not exist', :aggregate_failures do
      expect_refused(%w[2026-02-30 2025-02-29 2026-13-01 2026-00-10 2026-10-00 2026-10-32])
    end

    it 'refuses anything before or after the day, a line break too', :aggregate_failures do
      expect_refused(["2026-10-16\n", "\n2026-10-16", ' 2026-10-16', '2026-10-16 ', "x\n2026-10-16", "2026-10-16\nx"])
    end

    it 'refuses too few or too many digits in a part, and other separators', :aggregate_failures do
      expect_refused(%w[26-10-16 02026-10-16 2026-1-16 2026-010-16 2026-10-6 2026-10-016])
      expect_refused(%w[2026/10/16 2026.10.16 2026_10_16])
    end

    it 'refuses digits that are not ASCII' do
      expect_refused(['２０２６-１０-１６'])
    end

    it 'refuses nil, an empty text, a list and a hash', :aggregate_failures do
      expect_refused([nil, '', ['2026-10-16'], { 'date' => '2026-10-16' }])
    end
  end
end

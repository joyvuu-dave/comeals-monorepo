# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MealSchedule do
  # 2026-08-02 is a Sunday.
  let(:anchor) { Date.new(2026, 8, 2) }

  describe '#meal_day?' do
    it 'repeats a 1-week cycle every week' do
      schedule = described_class.new(weeks: [[0, 4]], anchor_date: anchor)

      expect(schedule.meal_day?(Date.new(2026, 8, 2))).to be true   # Sunday
      expect(schedule.meal_day?(Date.new(2026, 8, 6))).to be true   # Thursday
      expect(schedule.meal_day?(Date.new(2026, 8, 9))).to be true   # next Sunday
      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be false  # Monday
    end

    it 'alternates a 2-week cycle relative to the anchor' do
      schedule = described_class.new(weeks: [[0, 1, 4], [0, 2, 4]], anchor_date: anchor)

      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be true    # week 1 Monday
      expect(schedule.meal_day?(Date.new(2026, 8, 4))).to be false   # week 1 Tuesday
      expect(schedule.meal_day?(Date.new(2026, 8, 10))).to be false  # week 2 Monday
      expect(schedule.meal_day?(Date.new(2026, 8, 11))).to be true   # week 2 Tuesday
      expect(schedule.meal_day?(Date.new(2026, 8, 17))).to be true   # week 1 again
    end

    it 'treats an empty week as a skip week in a 3-week cycle' do
      schedule = described_class.new(weeks: [[1], [], [4]], anchor_date: anchor)

      expect(schedule.cycle_length).to eq 3
      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be true    # week 1 Monday
      expect(schedule.meal_day?(Date.new(2026, 8, 10))).to be false  # week 2 Monday
      expect(schedule.meal_day?(Date.new(2026, 8, 13))).to be false  # week 2 Thursday
      expect(schedule.meal_day?(Date.new(2026, 8, 20))).to be true   # week 3 Thursday
      expect(schedule.meal_day?(Date.new(2026, 8, 24))).to be true   # week 1 Monday again
    end

    # Floor division, not truncation: -3 / 7 must be -1 so the week before
    # the anchor is the last week of the cycle. Rewriting the arithmetic as
    # ((date - anchor) / 7).to_i truncates toward zero and breaks this.
    it 'lands on the right week for dates before the anchor' do
      schedule = described_class.new(weeks: [[0, 1, 4], [0, 2, 4]], anchor_date: anchor)

      expect(schedule.meal_day?(Date.new(2026, 7, 28))).to be true   # prior week Tuesday = week 2
      expect(schedule.meal_day?(Date.new(2026, 7, 27))).to be false  # prior week Monday
      expect(schedule.meal_day?(Date.new(2026, 7, 20))).to be true   # two weeks back Monday = week 1
      expect(schedule.meal_day?(Date.new(2026, 7, 6))).to be true    # four weeks back Monday = week 1
    end
  end

  describe '#upcoming_dates' do
    it 'returns the next count meal dates in order' do
      schedule = described_class.new(weeks: [[0, 1, 4], [0, 2, 4]], anchor_date: anchor)

      dates = schedule.upcoming_dates(from: Date.new(2026, 8, 2), count: 6)

      expect(dates).to eq [
        Date.new(2026, 8, 2),  # Sun
        Date.new(2026, 8, 3),  # Mon (week 1)
        Date.new(2026, 8, 6),  # Thu
        Date.new(2026, 8, 9),  # Sun
        Date.new(2026, 8, 11), # Tue (week 2)
        Date.new(2026, 8, 13)  # Thu
      ]
    end

    it 'skips holidays and keeps walking' do
      # Thanksgiving 2026 is Thursday November 26.
      schedule = described_class.new(weeks: [[4]], anchor_date: anchor)

      dates = schedule.upcoming_dates(from: Date.new(2026, 11, 19), count: 3)

      expect(dates).to eq [Date.new(2026, 11, 19), Date.new(2026, 12, 3), Date.new(2026, 12, 10)]
    end

    it 'raises instead of walking forever when every candidate is refused' do
      schedule = described_class.new(weeks: [[4]], anchor_date: anchor)
      allow(Meal).to receive(:is_holiday?).and_return(true)

      expect { schedule.upcoming_dates(from: anchor, count: 1) }
        .to raise_error(/looks broken/)
    end
  end

  describe '#dates_between' do
    it 'returns every meal date in the range, skipping holidays' do
      # Christmas 2026 and New Year's Day 2027 are both Fridays — both skipped.
      schedule = described_class.new(weeks: [[5]], anchor_date: anchor)

      dates = schedule.dates_between(Date.new(2026, 12, 11), Date.new(2027, 1, 8))

      expect(dates).to eq [Date.new(2026, 12, 11), Date.new(2026, 12, 18), Date.new(2027, 1, 8)]
    end
  end

  describe 'construction guards' do
    it 'refuses a schedule with no meal days' do
      expect { described_class.new(weeks: [[], []], anchor_date: anchor) }
        .to raise_error(ArgumentError, /no meal days/)
    end

    it 'refuses a cycle outside 1..6 weeks' do
      expect { described_class.new(weeks: [], anchor_date: anchor) }
        .to raise_error(ArgumentError, /1 to 6 weeks/)
      expect { described_class.new(weeks: Array.new(7) { [0] }, anchor_date: anchor) }
        .to raise_error(ArgumentError, /1 to 6 weeks/)
    end
  end
end

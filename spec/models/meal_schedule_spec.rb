# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MealSchedule do
  # The cycle is pinned to EPOCH (Sunday 2000-01-02): the week containing it
  # is week 1. For the August 2026 dates used here, the week of Sunday
  # 2026-07-26 is 1386 weeks after the epoch, so it is a week-1 week for both
  # a 2-week and a 3-week cycle (1386 is divisible by both), and the week of
  # Sunday 2026-08-02 is a week-2 week for both.
  describe 'EPOCH' do
    it 'is a Sunday and never changes' do
      # Stored schedules were arranged against this exact date (migration
      # 20260808120000). Changing it would silently rephase every multi-week
      # schedule.
      expect(described_class::EPOCH).to eq(Date.new(2000, 1, 2))
      expect(described_class::EPOCH.wday).to eq(0)
    end
  end

  describe '#week_index' do
    it 'counts weeks from the epoch around the cycle' do
      schedule = described_class.new(weeks: [[0], [1], [2]])

      expect(schedule.week_index(described_class::EPOCH)).to eq 0
      expect(schedule.week_index(Date.new(2000, 1, 9))).to eq 1
      expect(schedule.week_index(Date.new(2000, 1, 23))).to eq 0
      # 2026-08-02 is 1387 weeks after the epoch; 1387 mod 3 is 1.
      expect(schedule.week_index(Date.new(2026, 8, 2))).to eq 1
      # Floor division: the week before the epoch is the cycle's last week.
      expect(schedule.week_index(Date.new(1999, 12, 26))).to eq 2
    end
  end

  describe '#meal_day?' do
    it 'repeats a 1-week cycle every week' do
      schedule = described_class.new(weeks: [[0, 4]])

      expect(schedule.meal_day?(Date.new(2026, 8, 2))).to be true   # Sunday
      expect(schedule.meal_day?(Date.new(2026, 8, 6))).to be true   # Thursday
      expect(schedule.meal_day?(Date.new(2026, 8, 9))).to be true   # next Sunday
      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be false  # Monday
    end

    it 'alternates a 2-week cycle pinned to the epoch' do
      # Week 1 has Tuesday, week 2 has Monday. The week of 2026-08-02 is a
      # week-2 week (see the top comment), so 2026-08-03 is a Monday meal.
      schedule = described_class.new(weeks: [[0, 2, 4], [0, 1, 4]])

      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be true    # Monday, week 2
      expect(schedule.meal_day?(Date.new(2026, 8, 4))).to be false   # Tuesday, week 2
      expect(schedule.meal_day?(Date.new(2026, 8, 10))).to be false  # Monday, week 1
      expect(schedule.meal_day?(Date.new(2026, 8, 11))).to be true   # Tuesday, week 1
      expect(schedule.meal_day?(Date.new(2026, 8, 17))).to be true   # Monday, week 2 again
    end

    it 'treats an empty week as a skip week in a 3-week cycle' do
      # Week 1: Thursday. Week 2: Monday. Week 3: nothing. The week of
      # 2026-08-02 is a week-2 week (see the top comment).
      schedule = described_class.new(weeks: [[4], [1], []])

      expect(schedule.cycle_length).to eq 3
      expect(schedule.meal_day?(Date.new(2026, 8, 3))).to be true    # Monday, week 2
      expect(schedule.meal_day?(Date.new(2026, 8, 10))).to be false  # Monday, week 3
      expect(schedule.meal_day?(Date.new(2026, 8, 13))).to be false  # Thursday, week 3
      expect(schedule.meal_day?(Date.new(2026, 8, 20))).to be true   # Thursday, week 1
      expect(schedule.meal_day?(Date.new(2026, 8, 24))).to be true   # Monday, week 2 again
    end

    # Floor division, not truncation: -3 / 7 must be -1 so the week before
    # the epoch is the last week of the cycle. Rewriting the arithmetic as
    # ((date - EPOCH) / 7).to_i truncates toward zero and breaks this.
    it 'maps dates before the epoch to the right week' do
      schedule = described_class.new(weeks: [[0, 1, 4], [0, 2, 4]])

      expect(schedule.meal_day?(Date.new(1999, 12, 28))).to be true   # prior week Tuesday = week 2
      expect(schedule.meal_day?(Date.new(1999, 12, 27))).to be false  # prior week Monday
      expect(schedule.meal_day?(Date.new(1999, 12, 20))).to be true   # two weeks back Monday = week 1
      expect(schedule.meal_day?(Date.new(1999, 12, 6))).to be true    # four weeks back Monday = week 1
    end
  end

  describe '#upcoming_dates' do
    it 'returns the next count meal dates in order' do
      schedule = described_class.new(weeks: [[0, 2, 4], [0, 1, 4]])

      dates = schedule.upcoming_dates(from: Date.new(2026, 8, 2), count: 6)

      expect(dates).to eq [
        Date.new(2026, 8, 2),  # Sun
        Date.new(2026, 8, 3),  # Mon (week 2)
        Date.new(2026, 8, 6),  # Thu
        Date.new(2026, 8, 9),  # Sun
        Date.new(2026, 8, 11), # Tue (week 1)
        Date.new(2026, 8, 13)  # Thu
      ]
    end

    it 'skips holidays and keeps walking' do
      # Thanksgiving 2026 is Thursday November 26.
      schedule = described_class.new(weeks: [[4]])

      dates = schedule.upcoming_dates(from: Date.new(2026, 11, 19), count: 3)

      expect(dates).to eq [Date.new(2026, 11, 19), Date.new(2026, 12, 3), Date.new(2026, 12, 10)]
    end

    it 'raises instead of walking forever when every candidate is refused' do
      schedule = described_class.new(weeks: [[4]])
      allow(Meal).to receive(:is_holiday?).and_return(true)

      expect { schedule.upcoming_dates(from: Date.new(2026, 8, 2), count: 1) }
        .to raise_error(/looks broken/)
    end
  end

  describe '#dates_between' do
    it 'returns every meal date in the range, skipping holidays' do
      # Christmas 2026 and New Year's Day 2027 are both Fridays — both skipped.
      schedule = described_class.new(weeks: [[5]])

      dates = schedule.dates_between(Date.new(2026, 12, 11), Date.new(2027, 1, 8))

      expect(dates).to eq [Date.new(2026, 12, 11), Date.new(2026, 12, 18), Date.new(2027, 1, 8)]
    end
  end

  describe 'construction guards' do
    it 'refuses a schedule with no meal days' do
      expect { described_class.new(weeks: [[], []]) }
        .to raise_error(ArgumentError, /no meal days/)
    end

    it 'refuses a cycle outside 1..6 weeks' do
      expect { described_class.new(weeks: []) }
        .to raise_error(ArgumentError, /1 to 6 weeks/)
      expect { described_class.new(weeks: Array.new(7) { [0] }) }
        .to raise_error(ArgumentError, /1 to 6 weeks/)
    end
  end
end

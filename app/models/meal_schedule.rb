# frozen_string_literal: true

# The community's meal schedule as a value: a repeating cycle of weeks, each
# week a set of days (0 = Sunday .. 6 = Saturday). Weeks are Sunday-start.
#
# The cycle is pinned to the calendar by EPOCH, a fixed Sunday: the week
# containing EPOCH is week 1, the next week is week 2, and so on around the
# cycle, in both directions, forever. There is no per-community start date.
# Which calendar week gets which days is chosen by how the days are arranged
# across the week rows — moving a day to the other row shifts it by a week —
# and the admin form's preview shows the resulting dates. The exact value of
# EPOCH is arbitrary (any fixed Sunday gives some assignment of rows to
# calendar weeks), but it must never change: existing schedules were arranged
# against this value, and changing it would silently rephase every multi-week
# schedule. Migration 20260808120000 rotated stored rows against this exact
# date.
#
# This is the one home for "is this date a meal day". Community's rotation
# generator, the admin preview, and db/seeds.rb all go through it, so the
# schedule cannot mean different things in different places.
class MealSchedule
  MAX_WEEKS = 6
  MAX_MEALS_PER_ROTATION = 100
  EPOCH = Date.new(2000, 1, 2)

  attr_reader :weeks

  def initialize(weeks:)
    # Community validations and the communities_schedule_shape database
    # constraint should make these raises unreachable. They stay because this
    # object must not trust its caller: a schedule with no days would make
    # every date walk below run forever.
    raise ArgumentError, "cycle must be 1 to #{MAX_WEEKS} weeks, got #{weeks.inspect}" unless
      weeks.is_a?(Array) && weeks.length.between?(1, MAX_WEEKS)
    raise ArgumentError, 'schedule has no meal days' if weeks.flatten.empty?

    @weeks = weeks
  end

  def cycle_length
    weeks.length
  end

  # Whole weeks from EPOCH's week to `date`'s week (negative before it).
  # This is the one home for the epoch arithmetic: #week_index uses it, and
  # so does the admin grid (ScheduleWeekLabelHelper), which needs it without
  # a weeks array.
  def self.weeks_since_epoch(date)
    # (date - EPOCH) is an exact whole number of days, and Integer#/ floors,
    # so dates before the epoch count correctly too (for example -3 / 7
    # is -1, and -1 % 2 is 1 in Ruby). Do not rewrite this as
    # ((date - EPOCH) / 7).to_i — Rational#to_i truncates toward zero,
    # which is wrong for dates before the epoch. Pinned by specs.
    (date.to_date - EPOCH).to_i / 7
  end

  # Which week of the cycle (0-based) holds this date.
  def week_index(date)
    self.class.weeks_since_epoch(date) % cycle_length
  end

  def meal_day?(date)
    weeks[week_index(date)].include?(date.wday)
  end

  # The next `count` meal dates starting at `from`, skipping holidays.
  def upcoming_dates(from:, count:)
    dates = []
    date = from.to_date
    # A schedule with at least one day can always fill `count` dates: the six
    # holidays are single days a year, never a whole weekday forever. The cap
    # exists so a bad row that somehow got past every validation and database
    # constraint fails loudly instead of looping forever.
    scan_limit = (count * cycle_length * 7) + 366
    scanned = 0
    while dates.length < count
      if scanned > scan_limit
        raise "Scanned #{scanned} days from #{from} and found only #{dates.length} of " \
              "#{count} meal days — the schedule #{weeks.inspect} looks broken"
      end
      dates << date if meal_day?(date) && !Meal.is_holiday?(date)
      date = date.tomorrow
      scanned += 1
    end
    dates
  end

  # Every meal date in the range, skipping holidays. Used by db/seeds.rb.
  def dates_between(from, to)
    (from.to_date..to.to_date).select { |date| meal_day?(date) && !Meal.is_holiday?(date) }
  end
end

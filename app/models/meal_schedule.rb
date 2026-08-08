# frozen_string_literal: true

# The community's meal schedule as a value: a repeating cycle of weeks, each
# week a set of days (0 = Sunday .. 6 = Saturday), pinned to the calendar by
# an anchor date that names week 1. Weeks are Sunday-start.
#
# This is the one home for "is this date a meal day". Community's rotation
# generator, the admin preview, and db/seeds.rb all go through it, so the
# schedule cannot mean different things in different places.
class MealSchedule
  MAX_WEEKS = 6
  MAX_MEALS_PER_ROTATION = 100

  attr_reader :weeks, :anchor_date

  def initialize(weeks:, anchor_date:)
    # Community validations and the communities_schedule_shape database
    # constraint should make these raises unreachable. They stay because this
    # object must not trust its caller: a schedule with no days would make
    # every date walk below run forever.
    raise ArgumentError, "cycle must be 1 to #{MAX_WEEKS} weeks, got #{weeks.inspect}" unless
      weeks.is_a?(Array) && weeks.length.between?(1, MAX_WEEKS)
    raise ArgumentError, 'schedule has no meal days' if weeks.flatten.empty?

    @weeks = weeks
    @anchor_date = anchor_date.to_date
  end

  def cycle_length
    weeks.length
  end

  def meal_day?(date)
    # (date - anchor_date) is an exact whole number of days, and Integer#/
    # floors, so dates before the anchor get the right week too (for example
    # -3 / 7 is -1, and -1 % 2 is 1 in Ruby). Do not rewrite this as
    # ((date - anchor_date) / 7).to_i — Rational#to_i truncates toward zero,
    # which is wrong for dates before the anchor. Pinned by specs.
    week_index = ((date - anchor_date).to_i / 7) % cycle_length
    weeks[week_index].include?(date.wday)
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

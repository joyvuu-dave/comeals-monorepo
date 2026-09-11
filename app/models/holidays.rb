# typed: strict
# frozen_string_literal: true

# The days the community does not cook: the six US holidays below.
# MealSchedule skips them when it lays out meal dates. Pure date
# arithmetic, no database. The list is fixed in code because it has
# never needed to change; a community setting would be the next step
# if one did.
module Holidays
  extend T::Sig

  sig { params(date: Date).returns(T::Boolean) }
  def self.holiday?(date)
    thanksgiving?(date) ||
      christmas?(date) ||
      new_years_day?(date) ||
      mothers_day?(date) ||
      easter?(date) ||
      july_fourth?(date)
  end

  # The fourth Thursday of November.
  sig { params(date: Date).returns(T::Boolean) }
  def self.thanksgiving?(date)
    nth_weekday?(date, month: 11, wday: 4, nth: 4)
  end

  sig { params(date: Date).returns(T::Boolean) }
  def self.christmas?(date)
    date.month == 12 && date.day == 25
  end

  sig { params(date: Date).returns(T::Boolean) }
  def self.new_years_day?(date)
    date.month == 1 && date.day == 1
  end

  # The second Sunday of May.
  sig { params(date: Date).returns(T::Boolean) }
  def self.mothers_day?(date)
    nth_weekday?(date, month: 5, wday: 0, nth: 2)
  end

  # The anonymous Gregorian algorithm, as published in Nature in 1876.
  # The variable names are the algorithm's own, kept so it can be
  # checked against the source.
  sig { params(date: Date).returns(T::Boolean) }
  def self.easter?(date) # rubocop:disable Metrics/AbcSize -- the algorithm is arithmetic, and only arithmetic
    y = date.year
    a = y % 19
    b = y / 100
    c = y % 100
    d = b / 4
    e = b % 4
    f = (b + 8) / 25
    g = (b - f + 1) / 3
    h = ((19 * a) + b - d - g + 15) % 30
    i = c / 4
    k = c % 4
    l = (32 + (2 * e) + (2 * i) - h - k) % 7
    m = (a + (11 * h) + (22 * l)) / 451

    month = (h + l - (7 * m) + 114) / 31
    day = ((h + l - (7 * m) + 114) % 31) + 1

    date.month == month && date.day == day
  end

  sig { params(date: Date).returns(T::Boolean) }
  def self.july_fourth?(date)
    date.month == 7 && date.day == 4
  end

  # Whether `date` is the nth `wday` (0 = Sunday) of `month`. The nth
  # weekday of a month always falls in days 7n-6 to 7n: the first is in
  # 1..7, the second in 8..14, the fourth in 22..28.
  sig { params(date: Date, month: Integer, wday: Integer, nth: Integer).returns(T::Boolean) }
  def self.nth_weekday?(date, month:, wday:, nth:)
    date.month == month && date.wday == wday && date.day.between?((7 * nth) - 6, 7 * nth)
  end
  private_class_method :nth_weekday?
end

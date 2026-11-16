# typed: strict
# frozen_string_literal: true

# The days a person may put a new dinner, event or booking on: from 10
# years before today to 10 years after it, both ends included, and never
# after December 31, 9999 (challenge 6, decided 2026-11-15).
#
# The window is counted from the community's today each time, so it
# moves with the calendar and never runs out: in 3026 it goes to 3036.
# A date outside it is almost always a typo (0226 for 2026, 20266 for
# 2026), and refusing it keeps every date the app stores inside the
# years it is tested for.
#
# The last day is fixed because the app writes years with four digits
# (YearMonthDay, the date inputs, the calendar's URLs). From about 9989
# on, today plus 10 years would be the year 10000.
#
# February 29 plus or minus 10 years is February 28, as Rails' Date#advance
# moves it, so on a leap day the window starts and ends on February 28.
module CalendarWindow
  extend T::Sig

  YEARS = 10
  LAST_DAY = T.let(Date.new(9999, 12, 31), Date)
  MESSAGE = T.let("is more than #{YEARS} years from today".freeze, String)

  sig { params(today: Date).returns(T::Range[Date]) }
  def self.days(today)
    (today.advance(years: -YEARS))..[today.advance(years: YEARS), LAST_DAY].min
  end

  sig { params(day: Date, today: Date).returns(T::Boolean) }
  def self.cover?(day, today:)
    days(today).cover?(day)
  end
end

# typed: strict
# frozen_string_literal: true

# The instants a PostgreSQL timestamp column can hold, and the days a
# date column can hold. A value outside them is not refused by a CHECK
# constraint: PostgreSQL raises PG::DatetimeFieldOverflow when a
# statement uses the value, and a request answered 500. So a path that
# builds a time or a day from what a person sent checks it here first.
#
# The limits are fixed in PostgreSQL's source code; no setting changes
# them. Both kinds start at November 24, 4714 BC, which Ruby writes as
# year -4713 (Ruby counts 1 BC as year 0). A timestamp ends with the
# final microsecond of 294276 AD, in UTC; a date ends with December 31,
# 5874897 AD. PostgreSQL counts every day in the Gregorian calendar
# carried back before 1582, the same as Ruby's Time.
# spec/models/storable_time_spec.rb asks the database about each end.
module StorableTime
  extend T::Sig

  TIMESTAMPS = T.let(Time.utc(-4713, 11, 24)...Time.utc(294_277, 1, 1), T::Range[Time])
  DATES = T.let(Date.new(-4713, 11, 24, Date::GREGORIAN)..Date.new(5_874_897, 12, 31, Date::GREGORIAN),
                T::Range[Date])

  # Whether a timestamp column can hold this time. It is compared as an
  # instant, so a time in any zone is right: 16:00 on December 31, 294276
  # in Los Angeles is already 294277 in UTC, and is refused.
  sig { params(time: T.any(Time, ActiveSupport::TimeWithZone)).returns(T::Boolean) }
  def self.timestamp?(time)
    TIMESTAMPS.cover?(time)
  end

  # Whether a date column can hold this day. PostgreSQL gets the year,
  # month and day as written and reads them in the Gregorian calendar.
  # Ruby's Date writes a day before October 15, 1582 in the Julian
  # calendar, so the same year, month and day can be a different day,
  # or no day at all: February 29, 1500 is a Julian leap day that the
  # Gregorian calendar does not have.
  sig { params(date: Date).returns(T::Boolean) }
  def self.date?(date)
    year = date.year
    month = date.month
    day = date.day
    return false unless Date.valid_date?(year, month, day, Date::GREGORIAN)

    DATES.cover?(Date.new(year, month, day, Date::GREGORIAN))
  end
end

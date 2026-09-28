# typed: strict
# frozen_string_literal: true

# The instants a PostgreSQL timestamp column can hold. A time outside
# them is not refused by a CHECK constraint: PostgreSQL raises
# PG::DatetimeFieldOverflow when a statement uses the time, and a request
# answered 500. So a path that builds a time from what a person sent
# checks it here first.
#
# The limits are fixed in PostgreSQL's source code; no setting changes
# them. The first is midnight UTC on November 24, 4714 BC, which Ruby
# writes as year -4713 (Ruby counts 1 BC as year 0). The last is the
# final microsecond of 294276 AD. Both use the Gregorian calendar
# carried back before 1582, the same as PostgreSQL and Ruby's Time.
# spec/models/storable_time_spec.rb asks the database for both ends.
module StorableTime
  extend T::Sig

  TIMESTAMPS = T.let(Time.utc(-4713, 11, 24)...Time.utc(294_277, 1, 1), T::Range[Time])

  # Whether a timestamp column can hold this time. It is compared as an
  # instant, so a time in any zone is right: 16:00 on December 31, 294276
  # in Los Angeles is already 294277 in UTC, and is refused.
  sig { params(time: T.any(Time, ActiveSupport::TimeWithZone)).returns(T::Boolean) }
  def self.timestamp?(time)
    TIMESTAMPS.cover?(time)
  end
end

# typed: strict
# frozen_string_literal: true

# A day sent in a request, written exactly as YYYY-MM-DD: the one form
# public/api.md gives for the calendar's date, the birthdays start and
# the settlement cutoff, and the form the SPA and the admin pages send.
# Anything else raises Date::Error, which each caller answers as a bad
# date.
#
# Date.parse and Date.iso8601 alone take more, and some of it has no
# year or no month. They fill the missing part in from the machine's own
# clock, in the machine's own zone, not from the community's today
# (CLAUDE.md, "Every wall-clock time is a community setting"):
# Date.parse reads "12" as the 12th of this month, and Date.iso8601 reads
# "--10-12" as October 12 of this year and "2026-10" as October 1. Until
# 2026-10-16 the calendar read its date with Date.parse and the
# settlement cutoff with Date.iso8601, so a POST with cutoff "2026-10"
# settled up to October 1.
#
# The day is read in the Gregorian calendar, before 1582 too, as
# PostgreSQL reads it (StorableTime.date? says more). Ruby's Date reads a
# day before October 15, 1582 in the Julian calendar unless told
# otherwise, so "1500-02-29", a Julian leap day the Gregorian calendar
# does not have, reached the database, which refused the query.
module YearMonthDay
  extend T::Sig

  # The day `text` names, or Date::Error when `text` is not a String
  # written as YYYY-MM-DD, or names a day the Gregorian calendar does not
  # have ("2026-02-30", "1500-02-29"). Takes anything a request can
  # hold, a list or nil too.
  sig { params(text: T.untyped).returns(Date) }
  def self.parse(text)
    raise Date::Error, 'invalid date' unless text.is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(text)

    Date.iso8601(text, Date::GREGORIAN)
  end
end

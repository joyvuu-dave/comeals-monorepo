# typed: true
# frozen_string_literal: true

# `validates :date, calendar_window: true` refuses a day outside
# CalendarWindow with a form error, on a save that sets or changes the
# attribute. A save that leaves it alone is taken, so a dinner that has
# gone more than 10 years into the past can still be corrected.
#
# A Date is judged as it is. A time is judged by the day it falls on in
# the community's zone (Community#date_of), the day the calendar shows
# it on. A nil value is left to the presence rules, and a value the
# database cannot store to the storable_time rule, so a record gets one
# message for one wrong date.
class CalendarWindowValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.nil?
    return unless record.new_record? || record.will_save_change_to_attribute?(attribute)

    return unless value.is_a?(Date) ? StorableTime.date?(value) : StorableTime.timestamp?(value)

    community = record.community || Community.instance
    day = value.is_a?(Date) ? value : community.date_of(value)
    return if CalendarWindow.cover?(day, today: community.today)

    record.errors.add(attribute, CalendarWindow::MESSAGE)
  end
end

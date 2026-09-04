# typed: true
# frozen_string_literal: true

# Builds the iCal feeds (the webcal links on the calendar page): the
# calendar scaffolding with the community's timezone, and one event per
# meal. Dinner starts at the community's time for that weekday
# (Community#dinner_start_times) and runs two hours.
class MealIcalFeed
  DINNER_HOURS = 2

  def initialize(community, calendar_name:)
    require 'icalendar/tzinfo'
    @community = community
    @tzid = community.timezone
    @calendar = Icalendar::Calendar.new
    @calendar.add_timezone TZInfo::Timezone.get(@tzid).ical_timezone(DateTime.new(2017, 6, 1, 8, 0, 0))
    @calendar.x_wr_calname = calendar_name
  end

  def add_meal(meal, summary:, description:)
    event = Icalendar::Event.new
    event.dtstart = Icalendar::Values::DateTime.new(dinner_start(meal.date), 'tzid' => @tzid)
    event.dtend = Icalendar::Values::DateTime.new(dinner_end(meal.date), 'tzid' => @tzid)
    event.summary = summary
    event.description = description
    @calendar.add_event(event)
  end

  delegate :to_ical, to: :@calendar

  private

  # Icalendar wants the wall-clock value and gets the zone from `tzid`,
  # so these are built from the community's moment field by field: a
  # DateTime with its own offset would be read as that offset, not as
  # the zone's.
  def dinner_start(date)
    wall_clock(@community.dinner_start_at(date))
  end

  def dinner_end(date)
    wall_clock(@community.dinner_start_at(date) + DINNER_HOURS.hours)
  end

  def wall_clock(time)
    DateTime.new(time.year, time.month, time.day, time.hour, time.min)
  end
end

# frozen_string_literal: true

# Builds the iCal feeds (the webcal links on the calendar page): the
# calendar scaffolding with the community's timezone, and one event per
# meal. The dinner window is domain knowledge that used to live in
# three controller loops (#51): dinner starts at 18:00 on Sundays and
# 19:00 every other day, and runs two hours.
class MealIcalFeed
  SUNDAY_START_HOUR = 18
  WEEKDAY_START_HOUR = 19
  DINNER_HOURS = 2

  def initialize(community, calendar_name:)
    require 'icalendar/tzinfo'
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

  def dinner_start(date)
    DateTime.new(date.year, date.month, date.day, start_hour(date), 0)
  end

  def dinner_end(date)
    DateTime.new(date.year, date.month, date.day, start_hour(date) + DINNER_HOURS, 0)
  end

  def start_hour(date)
    date.sunday? ? SUNDAY_START_HOUR : WEEKDAY_START_HOUR
  end
end

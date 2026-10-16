# typed: true
# frozen_string_literal: true

# Builds the iCal feeds (the webcal links on the calendar page): the
# calendar scaffolding with the community's timezone, and one event per
# meal. Dinner starts at the community's time for that weekday
# (Community#dinner_start_times) and runs two hours.
class MealIcalFeed
  DINNER_HOURS = 2

  # `feed` names this feed in each event's UID: "community", or
  # "resident-<id>" for a person's own feed.
  def initialize(community, calendar_name:, feed:)
    require 'icalendar/tzinfo'
    @community = community
    @feed = feed
    @tzid = community.timezone
    @calendar = Icalendar::Calendar.new
    # The zone as the rules in force on one summer day: the summer and
    # winter offsets, and a yearly rule for each switch. Any day between
    # the two switches of a year with today's rules gives the same block
    # (spec/requests/api/v1/residents_ical_spec.rb pins it).
    @calendar.add_timezone TZInfo::Timezone.get(@tzid).ical_timezone(DateTime.new(2017, 6, 1))
    @calendar.x_wr_calname = calendar_name
  end

  # A cancelled dinner (ADR 0011 rule 11) stays in the feed with
  # STATUS:CANCELLED, the way RFC 5545 marks an event that was called
  # off, and its summary says so for a calendar app that does not show
  # the status.
  def add_meal(meal, summary:, description:)
    event = Icalendar::Event.new
    event.uid = uid(meal)
    event.dtstart = Icalendar::Values::DateTime.new(dinner_start(meal.date), 'tzid' => @tzid)
    event.dtend = Icalendar::Values::DateTime.new(dinner_end(meal.date), 'tzid' => @tzid)
    event.summary = meal.cancelled? ? "Cancelled: #{summary}" : summary
    event.status = 'CANCELLED' if meal.cancelled?
    event.description = description
    @calendar.add_event(event)
  end

  delegate :to_ical, to: :@calendar

  private

  # The same on every fetch. RFC 5545 tells events apart by UID, so a new
  # one each time (the gem's default, a random one) made a calendar app
  # read every dinner as a new event and drop the reminders people had
  # put on it (#166). The feed part keeps a person's event apart from the
  # community feed's for the same dinner, for someone subscribed to both.
  def uid(meal)
    "meal-#{meal.id}-#{@feed}@comeals.com"
  end

  # Icalendar writes the clock time of the value it is given and names
  # the zone with `tzid`. dinner_start_at answers in the community's zone,
  # so its clock time is that zone's.
  def dinner_start(date)
    @community.dinner_start_at(date)
  end

  def dinner_end(date)
    @community.dinner_start_at(date) + DINNER_HOURS.hours
  end
end

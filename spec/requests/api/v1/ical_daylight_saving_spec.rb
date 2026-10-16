# frozen_string_literal: true

require 'rails_helper'

# The iCal feed on the two days the clocks change in the community's zone
# (America/Los_Angeles): 2026-03-08, when 02:00 becomes 03:00, and
# 2026-11-01, when 02:00 comes twice. Dinner is at 19:00 on both, so its
# instant in UTC is an hour earlier after the March switch than before
# it, and an hour later after the November one.
#
# A calendar app reads DTSTART as a wall clock in its TZID and finds the
# offset in the feed's own VTIMEZONE. This does the same, so it checks
# what the app sends, not what Ruby would make of it.
RSpec.describe 'the iCal feed on a daylight-saving switch day' do
  let(:community) { create(:community) }

  # The instant each event starts, read the way a calendar app reads it.
  def start_instants(body)
    calendar = Icalendar::Calendar.parse(body).sole
    zone = calendar.timezones.sole
    calendar.events.map do |event|
      expect(event.dtstart.ical_params['tzid']).to eq([zone.tzid.to_s])
      wall = DateTime.strptime(event.dtstart.value_ical, '%Y%m%dT%H%M%S')
      offset = zone.offset_for_local(wall).value_ical
      Time.new(wall.year, wall.month, wall.day, wall.hour, wall.minute, 0, offset).utc.iso8601
    end.sort
  end

  it 'starts each dinner at 19:00 in the zone, on both sides of each switch' do
    expect(community.timezone).to eq('America/Los_Angeles')
    [Date.new(2026, 3, 7), Date.new(2026, 3, 8), Date.new(2026, 10, 31), Date.new(2026, 11, 1)].each do |date|
      create(:meal, community: community, date: date)
    end

    get "/api/v1/communities/#{community.id}/ical"

    expect(start_instants(response.body)).to eq(
      [
        '2026-03-08T03:00:00Z', # Saturday 2026-03-07, 19:00 PST (-08:00)
        '2026-03-09T02:00:00Z', # Sunday 2026-03-08, 19:00 PDT (-07:00)
        '2026-11-01T02:00:00Z', # Saturday 2026-10-31, 19:00 PDT (-07:00)
        '2026-11-02T03:00:00Z'  # Sunday 2026-11-01, 19:00 PST (-08:00)
      ]
    )
  end
end

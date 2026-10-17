# frozen_string_literal: true

require 'rails_helper'

# What a change of the community's time zone does to the calendar, read
# before the change is saved (#173). The stored times of events and
# common house bookings are instants, so they stay. What people see is
# the clock time in the community's zone, and that moves: 20:00 in Los
# Angeles is 23:00 in New York. An event that moves past midnight ends on
# the next day, and an all-day event can show on another day. The admin
# community form shows these numbers before it saves a new zone.
#
# The community is in Los Angeles. The days include both daylight
# saving days there.
RSpec.describe ZoneChange do
  let!(:community) { create(:community, timezone: 'America/Los_Angeles') }
  let(:resident) { create(:resident, community: community) }

  def timed_event(start, finish, title: 'Movie night')
    create(:event, community: community, title: title, start_date: start, end_date: finish, allday: false)
  end

  def booking(start, finish, title: 'Party')
    create(:common_house_reservation, community: community, resident: resident, title: title,
                                      start_date: start, end_date: finish)
  end

  def change_to(zone)
    described_class.new(community, zone)
  end

  describe '#moved_count' do
    # Phoenix has no daylight saving time. In summer it shows the same
    # clock time as Los Angeles (both UTC-7), in winter one hour later.
    # On the day the clocks go forward, 01:00 is still winter time and
    # 20:00 is summer time.
    it 'counts the timed events and bookings whose clock times change, and only those' do
      timed_event(Time.zone.local(2026, 1, 15, 14), Time.zone.local(2026, 1, 15, 15))
      timed_event(Time.zone.local(2026, 4, 15, 14), Time.zone.local(2026, 4, 15, 15))
      booking(Time.zone.local(2026, 3, 8, 1), Time.zone.local(2026, 3, 8, 1, 30))
      booking(Time.zone.local(2026, 3, 8, 20), Time.zone.local(2026, 3, 8, 21))

      expect(change_to('America/Phoenix').moved_count).to eq(2)
      expect(change_to('America/New_York').moved_count).to eq(4)
      expect(change_to('America/Los_Angeles').moved_count).to eq(0)
    end

    # The night the clocks go back, Phoenix is UTC-7 all night and Los
    # Angeles moves from UTC-7 to UTC-8 at 02:00. A booking from 00:30
    # to 03:00 starts at the same clock time in both and ends at another.
    it 'counts a row whose end moves even when its start does not' do
      booking(Time.zone.local(2026, 11, 1, 0, 30), Time.zone.local(2026, 11, 1, 3))

      expect(change_to('America/Phoenix').moved_count).to eq(1)
    end

    it 'leaves out all-day events' do
      create(:event, community: community, allday: true, start_date: Time.zone.local(2026, 4, 15), end_date: nil)

      expect(change_to('America/New_York').moved_count).to eq(0)
    end
  end

  # An all-day event is saved as midnight in the community's zone and
  # shows on that day. Midnight in Los Angeles is 21:00 or 22:00 the day
  # before in Honolulu, and 03:00 the same day in New York.
  describe '#all_day_moved_count' do
    it 'counts the all-day events that would show on another day' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
        create(:event, community: community, allday: true, start_date: Time.zone.local(*day), end_date: nil)
      end
      timed_event(Time.zone.local(2026, 4, 15, 0, 30), Time.zone.local(2026, 4, 15, 1))

      expect(change_to('Pacific/Honolulu').all_day_moved_count).to eq(3)
      expect(change_to('America/New_York').all_day_moved_count).to eq(0)
    end
  end

  describe '#crossing_count and #crossing' do
    # 20:00 to 23:00 in Los Angeles is 23:00 to 02:00 in New York, on an
    # ordinary day and on both daylight saving days. 14:00 to 15:00 stays
    # on one day. A notice, midnight to the same midnight, is one day in
    # every zone. An all-day event has no end that counts.
    it 'counts and lists the timed events and bookings that would cross midnight, first by start' do
      timed_event(Time.zone.local(2026, 11, 1, 20), Time.zone.local(2026, 11, 1, 23), title: 'Late')
      booking(Time.zone.local(2026, 3, 8, 20), Time.zone.local(2026, 3, 8, 23), title: 'Dance')
      timed_event(Time.zone.local(2026, 4, 15, 20), Time.zone.local(2026, 4, 15, 23), title: 'Movie')
      timed_event(Time.zone.local(2026, 4, 16, 14), Time.zone.local(2026, 4, 16, 15), title: 'Early')
      midnight = Time.zone.local(2026, 4, 17)
      booking(midnight, midnight, title: 'Notice')
      create(:event, community: community, allday: true, start_date: Time.zone.local(2026, 4, 18),
                     end_date: Time.zone.local(2026, 4, 20))

      change = change_to('America/New_York')

      expect(change.crossing_count).to eq(3)
      expect(change.crossing.map { |row| [row.kind, row.title, row.day] })
        .to eq([['Common house booking', 'Dance', Date.new(2026, 3, 8)],
                ['Event', 'Movie', Date.new(2026, 4, 15)],
                ['Event', 'Late', Date.new(2026, 11, 1)]])
      expect(change_to('America/Denver').crossing_count).to eq(0)
    end

    it 'lists only the first ten, and counts them all' do
      12.times do |n|
        start = Time.zone.local(2026, 5, 1 + n, 21)
        timed_event(start, start + 2.hours, title: "Night #{n + 1}")
      end

      change = change_to('America/New_York')

      expect(change.crossing_count).to eq(12)
      expect(change.crossing.map(&:title)).to eq((1..10).map { |n| "Night #{n}" })
    end

    # The day shown is the day people see now, in the current zone. 23:30
    # in Los Angeles is already the next day in New York.
    it 'gives the day in the current zone' do
      timed_event(Time.zone.local(2026, 4, 15, 21, 30), Time.zone.local(2026, 4, 15, 23, 30))

      expect(change_to('America/New_York').crossing.map(&:day)).to eq([Date.new(2026, 4, 15)])
    end
  end

  describe '#any?' do
    it 'is true when something on the calendar would move, false when nothing would' do
      expect(change_to('America/New_York').any?).to be(false)

      create(:event, community: community, allday: true, start_date: Time.zone.local(2026, 4, 15), end_date: nil)
      expect(change_to('America/New_York').any?).to be(false)
      expect(change_to('Pacific/Honolulu').any?).to be(true)

      timed_event(Time.zone.local(2026, 4, 16, 14), Time.zone.local(2026, 4, 16, 15))
      expect(change_to('America/New_York').any?).to be(true)
    end
  end
end

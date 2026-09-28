# frozen_string_literal: true

require 'rails_helper'

# The two pieces of the calendar cache that live on Community: which
# months a changed day reaches, and the version a stored month is read
# under (CLAUDE.md, "No denormalized counters or caches").
RSpec.describe Community do
  let(:community) { create(:community) }

  describe '#affected_calendar_keys' do
    def keys(*months)
      months.map { |year, month| community.calendar_cache_key(year, month) }
    end

    # A month's calendar is six weeks from the Sunday on or before the
    # 1st. March 2026 starts on a Sunday, so its calendar runs March 1 to
    # April 11; April's runs March 29 to May 9; May's starts on Sunday
    # April 26.
    it 'is the month itself for a day no other month shows' do
      expect(community.affected_calendar_keys(Date.new(2026, 4, 15))).to eq(keys([2026, 4]))
    end

    it 'adds the previous month up to the last day of its six weeks, and not one day more' do
      expect(community.affected_calendar_keys(Date.new(2026, 4, 11))).to eq(keys([2026, 3], [2026, 4]))
      expect(community.affected_calendar_keys(Date.new(2026, 4, 12))).to eq(keys([2026, 4]))
    end

    it 'adds the next month from the Sunday its calendar starts on, and not one day earlier' do
      expect(community.affected_calendar_keys(Date.new(2026, 4, 26))).to eq(keys([2026, 4], [2026, 5]))
      expect(community.affected_calendar_keys(Date.new(2026, 4, 25))).to eq(keys([2026, 4]))
    end

    it 'takes a time as its date' do
      expect(community.affected_calendar_keys(Time.zone.local(2026, 4, 11, 18, 0))).to eq(keys([2026, 3], [2026, 4]))
    end
  end

  describe '#calendar_cache_version' do
    include ActiveSupport::Testing::TimeHelpers

    # April 2026's six weeks.
    let(:from) { Date.new(2026, 3, 29) }
    let(:to) { Date.new(2026, 5, 9) }

    def version
      community.calendar_cache_version(from, to)
    end

    it 'starts with the community day, then a count and a newest change for each table' do
      create(:unit, community: community)
      parts = version.delete_prefix("#{community.today}-").split('-', -1)

      # The newest change of the community, then a count and a newest
      # change for residents, units, meals, rotations, events, common
      # house and guest room.
      expect(parts.length).to eq(15)
      expect(parts.values_at(1, 3, 5, 7, 9, 11, 13)).to all(match(/\A\d+\z/))
      expect(parts[3]).to eq('1')
    end

    it 'changes when the day changes, with no row changed' do
      before = version

      travel 1.day do
        expect(version).not_to eq(before)
        expect(version).to start_with("#{community.today}-")
      end
    end

    it 'carries the newest change to the microsecond, so two saves in one second differ' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 10))

      expect(version).to include(meal.reload.updated_at.utc.strftime('%Y%m%d%H%M%S%6N'))
    end

    it 'changes when a meal in the six weeks changes, and not when one outside does' do
      inside = create(:meal, community: community, date: Date.new(2026, 4, 10))
      outside = create(:meal, community: community, date: Date.new(2026, 6, 10))
      before = version

      outside.touch
      expect(version).to eq(before)

      inside.touch
      expect(version).not_to eq(before)
    end

    it 'counts an event on the last day of the six weeks, whatever the hour' do
      before = version

      create(:event, community: community, start_date: Time.zone.local(2026, 5, 9, 14, 0),
                     end_date: Time.zone.local(2026, 5, 9, 16, 0))

      expect(version).not_to eq(before)
    end

    # The admin form takes any start and end, so a booking can last days.
    # One that starts the day before the six weeks is on April's calendar,
    # so each write to it must be a miss for April's stored copy.
    it 'changes when a common house booking that starts before the six weeks is made, changed or removed' do
      resident = create(:resident, community: community)
      before = version

      booking = create(:common_house_reservation, community: community, resident: resident,
                                                  start_date: Time.zone.local(2026, 3, 28, 18),
                                                  end_date: Time.zone.local(2026, 4, 3, 10))
      made = version
      expect(made).not_to eq(before)

      booking.update!(title: 'Moving day')
      changed = version
      expect(changed).not_to eq(made)

      booking.destroy!
      expect(version).not_to eq(changed)
    end

    # The version must see exactly the bookings the month shows: one it
    # misses can be served stale for an hour, and one it counts but the
    # month leaves out only costs a rebuild. The count and the newest
    # change are read one by one, because each has its own WHERE. Each
    # booking is made alone, because two that overlap cannot both be
    # saved.
    it 'counts a common house booking exactly when April lists it' do
      resident = create(:resident, community: community)
      april = { month: 4, year: 2026, start_date: from.to_s, end_date: to.to_s, month_int_array: [3, 4, 5] }

      bookings = {
        'ends as the six weeks open' => [[3, 28, 22, 0], [3, 29, 0, 0]],
        'ends a minute before they open' => [[3, 28, 22, 0], [3, 28, 23, 59]],
        'starts before them and ends inside' => [[3, 28, 18, 0], [4, 3, 10, 0]],
        'starts on the last day and ends after' => [[5, 9, 23, 0], [5, 11, 10, 0]],
        'starts at their last microsecond' => [[5, 9, 23, 59, 59.999999r], [5, 10, 2, 0]],
        'spans them' => [[3, 20, 12, 0], [5, 20, 12, 0]],
        'starts as they close' => [[5, 10, 0, 0], [5, 10, 2, 0]]
      }

      seen = bookings.transform_values do |(start_parts, end_parts)|
        booking = create(:common_house_reservation, community: community, resident: resident,
                                                    start_date: Time.zone.local(2026, *start_parts),
                                                    end_date: Time.zone.local(2026, *end_parts))
        listed = CalendarSerializer.new(community, params: april).to_h[:common_house_reservations].any?
        # The common house count and newest change, after the community
        # day (see the first example for the order).
        count, newest = version.delete_prefix("#{community.today}-").split('-', -1).values_at(11, 12)
        newest_is_it = newest == booking.reload.updated_at.utc.strftime('%Y%m%d%H%M%S%6N')
        booking.destroy!
        { listed: listed, count: count, newest_is_it: newest_is_it }
      end

      both = { listed: true, count: '1', newest_is_it: true }
      neither = { listed: false, count: '0', newest_is_it: false }
      expect(seen).to eq('ends as the six weeks open' => both, 'ends a minute before they open' => neither,
                         'starts before them and ends inside' => both, 'starts on the last day and ends after' => both,
                         'starts at their last microsecond' => both, 'spans them' => both,
                         'starts as they close' => neither)
    end

    it 'reads the six weeks in the zone of the request, not the machine' do
      Time.use_zone('Asia/Tokyo') do
        before = version

        create(:event, community: community, start_date: Time.zone.local(2026, 3, 29, 0, 30),
                       end_date: Time.zone.local(2026, 3, 29, 1, 30))

        expect(version).not_to eq(before)
      end
    end

    it 'ends the six weeks at midnight in the zone of the request, not the machine' do
      Time.use_zone('Asia/Tokyo') do
        before = version

        create(:event, community: community, start_date: Time.zone.local(2026, 5, 10, 3, 0),
                       end_date: Time.zone.local(2026, 5, 10, 4, 0))

        expect(version).to eq(before)
      end
    end
  end
end

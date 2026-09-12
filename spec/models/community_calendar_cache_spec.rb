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

    it 'starts with the community day and joins every part with a dash' do
      expect(version).to start_with("#{community.today}-")
      # The day is three parts; then one count and one newest updated_at
      # for the community, residents, units, meals, rotations, events,
      # common house and guest room.
      expect(version.count('-')).to eq(2 + 15)
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

    it 'reads the six weeks in the zone of the request, not the machine' do
      Time.use_zone('Asia/Tokyo') do
        before = version

        create(:event, community: community, start_date: Time.zone.local(2026, 3, 29, 0, 30),
                       end_date: Time.zone.local(2026, 3, 29, 1, 30))

        expect(version).not_to eq(before)
      end
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# An event or a common house booking must start and end on the same day
# in the community's zone (#154). The models refuse an end on a later day
# with a sentence (starts_and_ends_on_one_day). These triggers make
# PostgreSQL refuse it too: from every write that skips the model, and
# from two copies of one row saved one after the other, one with a new
# start and one with a new end.
#
# Triggers, not CHECKs: the day depends on the community's zone, which
# is in another table. Each trigger runs only when a write sets the times
# (or, for an event, all day), so a row that ends on a later day only
# because the zone changed can still get a new title.
#
# The days are an ordinary one and both daylight saving days in Los
# Angeles, the community's zone.
RSpec.describe 'events and common house bookings last one day' do
  let!(:resident) { create(:resident) }
  let(:community) { resident.community }
  let(:days) { [[2026, 4, 12], [2026, 3, 8], [2026, 11, 1]] }
  let(:refused) { %w[common_house_reservations_one_day events_one_day] }

  # Rows written the way psql or insert_all writes them: no model.
  def booking(start, finish)
    CommonHouseReservation.insert!({ community_id: community.id, resident_id: resident.id,
                                     start_date: start, end_date: finish }, returning: :id).first['id']
  end

  def event(start, finish, allday: false)
    Event.insert!({ community_id: community.id, title: 'Spec', allday: allday,
                    start_date: start, end_date: finish }, returning: :id).first['id']
  end

  # The name of the rule that refused the write, or nil when it was
  # taken. Each write runs in its own savepoint: a refused statement ends
  # the transaction it runs in, and the example's transaction must go on.
  def refused_by(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
    nil
  rescue ActiveRecord::CheckViolation => e
    e.cause.result.error_field(PG::Constants::PG_DIAG_CONSTRAINT_NAME)
  end

  def both_refused_by(start, finish)
    [refused_by { booking(start, finish) }, refused_by { event(start, finish) }]
  end

  it 'refuses a booking or an event that ends on a later day, and says which row and which days' do
    start = Time.zone.local(2026, 4, 12, 22, 0)

    expect(both_refused_by(start, start + 3.hours)).to eq(refused)
    words = 'INSERT on common_house_reservations refused: row \d+ starts on 2026-04-12 and ends on 2026-04-13 ' \
            'in America/Los_Angeles\. It must start and end on the same day\.'
    expect { booking(start, start + 3.hours) }.to raise_error(ActiveRecord::CheckViolation, Regexp.new(words))
  end

  it 'takes one from 00:30 to 23:30, which is two days in UTC' do
    days.each do |day|
      start = Time.zone.local(*day, 0, 30)
      finish = Time.zone.local(*day, 23, 30)

      expect(start.utc.to_date).not_to eq(finish.utc.to_date)
      expect(both_refused_by(start, finish)).to eq([nil, nil])
    end
  end

  # 23:00 to 00:30 is one day in UTC: 06:00 to 07:30, or 07:00 to 08:30
  # in winter.
  it 'refuses one that runs past midnight, even when UTC sees one day' do
    days.each do |day|
      start = Time.zone.local(*day, 23, 0)
      finish = start + 90.minutes

      expect(start.utc.to_date).to eq(finish.utc.to_date)
      expect(both_refused_by(start, finish)).to eq(refused)
    end
  end

  # Midnight is the first moment of the next day. A notice runs from a
  # midnight to the same midnight.
  it 'refuses one that ends at the next midnight, and takes a notice' do
    days.each do |day|
      midnight = Time.zone.local(*day)
      next_day = Date.new(*day) + 1
      next_midnight = Time.zone.local(next_day.year, next_day.month, next_day.day)

      expect(both_refused_by(Time.zone.local(*day, 22, 0), next_midnight)).to eq(refused)
      expect(both_refused_by(midnight, midnight)).to eq([nil, nil])
    end
  end

  # 20:00 to 22:00 in Los Angeles is 23:00 to 01:00 in New York, and
  # 23:00 to 00:30 is 02:00 to 03:30.
  it 'reads the day in the community zone' do
    community.update_columns(timezone: 'America/New_York')
    evening = Time.zone.local(2026, 4, 12, 20, 0)
    late = Time.zone.local(2026, 4, 12, 23, 0)

    expect(both_refused_by(evening, evening + 2.hours)).to eq(refused)
    expect(both_refused_by(late, late + 90.minutes)).to eq([nil, nil])
  end

  # The model refuses a timed event with no end in its own words
  # (end_date_or_allday). Turning all day off makes the end count.
  it 'leaves an all-day event, and an event with no end, alone' do
    start = Time.zone.local(2026, 4, 12)
    all_day = event(start, start + 3.days, allday: true)

    expect(refused_by { event(start + 22.hours, nil) }).to be_nil
    expect(refused_by { Event.find(all_day).update_columns(title: 'Still all day') }).to be_nil
    expect(refused_by { Event.find(all_day).update_columns(allday: false) }).to eq('events_one_day')
  end

  # PostgreSQL stores a timestamp from midnight UTC on November 24,
  # 4714 BC (Ruby's year -4713). Los Angeles kept local mean time then,
  # 7:52:58 behind UTC, so the first hours it can store are a local time
  # it cannot store, and reading them in the zone fails. The model takes
  # such a time (StorableTime, #102) and checks its day itself, so the
  # trigger must not fail the write. It leaves a time less than a day
  # from either end to the model, even one that ends on a later day.
  it 'leaves a time less than a day from the first or last one PostgreSQL can store to the model' do
    first = Time.utc(-4713, 11, 24, 0, 0, 58)
    last = Time.utc(294_276, 12, 31, 23, 59)

    expect(both_refused_by(first, first + 1.hour)).to eq([nil, nil])
    expect(both_refused_by(last - 1.hour, last)).to eq([nil, nil])
    # 23:08 to 01:08 in Los Angeles: on the first day it can store, and
    # a day later.
    expect(both_refused_by(first + 7.hours, first + 9.hours)).to eq([nil, nil])
    expect(both_refused_by(first + 1.day + 7.hours, first + 1.day + 9.hours)).to eq(refused)
  end

  # After a change of zone, a row can end on a later day without any
  # write. Only a write that sets the times is checked, even when it sets
  # them to what they were.
  it 'checks a row again only when a write sets its times' do
    start = Time.zone.local(2026, 4, 12, 20, 0)
    booked = CommonHouseReservation.find(booking(start, start + 2.hours))
    timed = Event.find(event(start, start + 2.hours))
    community.update_columns(timezone: 'America/New_York')

    expect([booked, timed].map { |row| refused_by { row.update_columns(title: 'Renamed') } }).to eq([nil, nil])
    expect([booked, timed].map { |row| refused_by { row.update_columns(start_date: start) } }).to eq(refused)
    expect(refused_by { timed.update_columns(allday: false) }).to eq('events_one_day')
  end
end

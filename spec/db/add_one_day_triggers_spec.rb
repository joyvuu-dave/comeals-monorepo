# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009171800_add_one_day_triggers.rb')

# The migration that adds the one-day triggers checks the rows already
# there, the way a CHECK added NOT VALID is validated: it refuses to
# finish while an event or a booking starts and ends on different days,
# and names each one with its times in the community's zone, the way
# admin shows them. A trigger checks only new writes, so without this a
# row from before #154 would stay as it is, and be refused on every save
# from the forms.
RSpec.describe AddOneDayTriggers do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:resident) { create(:resident) }

  def at(day, hour, minute = 0)
    Time.zone.local(2026, 4, day, hour, minute)
  end

  def booking(start, finish)
    CommonHouseReservation.insert!({ community_id: resident.community_id, resident_id: resident.id,
                                     start_date: start, end_date: finish }, returning: :id).first['id']
  end

  def event(start, finish, allday: false)
    Event.insert!({ community_id: resident.community_id, title: 'Spec', allday: allday,
                    start_date: start, end_date: finish }, returning: :id).first['id']
  end

  # suppress_messages keeps the migration's "-- select_rows ..." lines
  # out of the RSpec output.
  def refuse_rows_on_two_days!
    migration = described_class.new
    migration.suppress_messages { migration.send(:refuse_rows_on_two_days) }
  end

  # The triggers forbid the rows below, so turn them off for each example
  # (rolled back with the transaction).
  before do
    connection.execute('ALTER TABLE events DISABLE TRIGGER events_one_day')
    connection.execute('ALTER TABLE common_house_reservations DISABLE TRIGGER common_house_reservations_one_day')
  end

  # 16:00 to 18:00 in Los Angeles is two days in UTC, and an all-day
  # event's end does not count. A time less than a day from the first or
  # last one PostgreSQL can store is left to the model, as the trigger
  # leaves it (spec/db/one_day_triggers_spec.rb): reading the first hours
  # in Los Angeles fails.
  it 'passes when every row is one day in the community zone, or too near the edges of time to read' do
    booking(at(12, 16), at(12, 18))
    booking(at(12, 0), at(12, 0))
    booking(Time.utc(-4713, 11, 24, 0, 0, 58), Time.utc(-4713, 11, 24, 9))
    event(at(12, 16), at(12, 18))
    event(at(12, 20), nil)
    event(at(12, 0), at(15, 0), allday: true)
    event(Time.utc(294_276, 12, 31, 7), Time.utc(294_276, 12, 31, 9))

    expect { refuse_rows_on_two_days! }.not_to raise_error
  end

  # 23:00 to 00:30 is one day in UTC.
  it 'refuses, naming each row and its times, when a row ends on a later day' do
    late = booking(at(12, 22), at(13, 1))
    booking(at(14, 9), at(14, 10))
    past_midnight = event(at(12, 23), at(13, 0, 30))
    event(at(14, 9), at(14, 10))

    expect { refuse_rows_on_two_days! }.to raise_error(
      RuntimeError,
      '2 row(s) start and end on different days: ' \
      "common house booking #{late} (2026-04-12 22:00 to 2026-04-13 01:00), " \
      "event #{past_midnight} (2026-04-12 23:00 to 2026-04-13 00:30). " \
      'Times are in America/Los_Angeles. Fix each one, then run this migration again.'
    )
  end
end

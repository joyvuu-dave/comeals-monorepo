# frozen_string_literal: true

require 'rails_helper'

# Every dated thing a person puts on the calendar refuses a day outside
# CalendarWindow when a save sets or changes that day, and takes a save
# that leaves it alone (challenge 6). Each way in (the API, admin) is in
# spec/requests/calendar_window_entry_points_spec.rb.
RSpec.describe CalendarWindowValidator do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community, timezone: 'America/Los_Angeles') }
  let(:zone) { ActiveSupport::TimeZone['America/Los_Angeles'] }
  let(:message) { CalendarWindow::MESSAGE }

  # 2026-11-15 at 8 PM in Los Angeles, which is already 2026-11-16 in UTC,
  # so a window counted from the UTC day would be one day off.
  before { travel_to zone.local(2026, 11, 15, 20) }

  def at(*parts)
    zone.local(*parts)
  end

  shared_examples 'a dated record' do |attribute|
    it 'takes a day at each end of the window' do
      expect(build_on(first_day)).to be_valid
      expect(build_on(last_day)).to be_valid
    end

    it 'refuses the day before the window and the day after it' do
      [first_day - 1.day, last_day + 1.day].each do |day|
        record = build_on(day)
        expect(record).not_to be_valid
        expect(record.errors[attribute]).to eq([message])
      end
    end

    it 'refuses a save that moves the day out of the window' do
      record = build_on(first_day)
      record.save!
      move(record, last_day + 1.day)

      expect(record).not_to be_valid
      expect(record.errors[attribute]).to eq([message])
    end

    it 'takes a save that leaves a day the window has since passed' do
      record = build_on(first_day)
      record.save!
      travel 1.day
      touch_something_else(record)

      expect(record).to be_valid
    end
  end

  describe Meal do
    def build_on(day) = build(:meal, community: community, date: day)
    def move(meal, day) = meal.date = day
    def touch_something_else(meal) = meal.description = 'Soup'
    let(:first_day) { Date.new(2016, 11, 15) }
    let(:last_day) { Date.new(2036, 11, 15) }

    it_behaves_like 'a dated record', :date
  end

  describe GuestRoomReservation do
    def build_on(day) = build(:guest_room_reservation, community: community, date: day)
    def move(booking, day) = booking.date = day
    def touch_something_else(booking) = booking.resident = create(:resident, community: community)
    let(:first_day) { Date.new(2016, 11, 15) }
    let(:last_day) { Date.new(2036, 11, 15) }

    it_behaves_like 'a dated record', :date
  end

  describe Event do
    def build_on(time) = build(:event, community: community, start_date: time, end_date: time + 1.hour)
    def move(event, time) = event.assign_attributes(start_date: time, end_date: time + 1.hour)
    def touch_something_else(event) = event.title = 'Moved'
    let(:first_day) { at(2016, 11, 15, 9) }
    let(:last_day) { at(2036, 11, 15, 9) }

    it_behaves_like 'a dated record', :start_date

    it 'refuses an end outside the window' do
      event = build(:event, community: community, allday: true,
                            start_date: at(2036, 11, 15), end_date: at(2036, 11, 16))

      expect(event).not_to be_valid
      expect(event.errors[:end_date]).to eq([message])
    end

    it 'judges a time by its day in the community zone' do
      # 11 PM on the last day in Los Angeles is the next day in UTC.
      expect(build_on(at(2036, 11, 15, 22))).to be_valid
    end
  end

  describe CommonHouseReservation do
    def build_on(time)
      build(:common_house_reservation, community: community, start_date: time, end_date: time + 1.hour)
    end

    def move(booking, time) = booking.assign_attributes(start_date: time, end_date: time + 1.hour)
    def touch_something_else(booking) = booking.title = 'Moved'
    let(:first_day) { at(2016, 11, 15, 9) }
    let(:last_day) { at(2036, 11, 15, 9) }

    it_behaves_like 'a dated record', :start_date
  end

  it 'gives one message, the database one, for a day the database cannot store' do
    meal = build(:meal, community: community, date: Date.new(5_874_898, 1, 1))

    expect(meal).not_to be_valid
    expect(meal.errors[:date]).to eq(['is not a date the database can store'])
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Every way a person can put a dinner, event or booking on a day refuses
# a day outside CalendarWindow (10 years before or after today) with the
# same words, and saves nothing (challenge 6). The rule itself is in
# spec/models/calendar_window_validator_spec.rb; this checks that each
# way in reaches it and shows its words, and does not answer with an
# error page. Rake tasks and the console save through the same models.
RSpec.describe 'Dates outside the calendar window, at every entry point' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community, timezone: 'America/Los_Angeles') }
  let(:zone) { ActiveSupport::TimeZone['America/Los_Angeles'] }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:words) { CalendarWindow::MESSAGE }

  # The first day past the window at each end, and a day inside.
  let(:too_old) { Date.new(2016, 11, 14) }
  let(:too_far) { Date.new(2036, 11, 16) }
  let(:inside) { Date.new(2036, 11, 15) }

  before { travel_to zone.local(2026, 11, 15, 12) }

  def parts(day, from: 18, to: 19)
    { start_year: day.year, start_month: day.month, start_day: day.day,
      start_hours: from, start_minutes: 0, end_hours: to, end_minutes: 0 }
  end

  describe 'the API' do
    let(:token) { resident.keys.first.token }

    def expect_refused(*attributes)
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => attributes.map { |name| "#{name} #{words}" }.join("\n"))
    end

    describe 'an event' do
      it 'refuses a new one at either end, and takes the last day inside' do
        [too_old, too_far].each do |day|
          post '/api/v1/events', params: { token: token, title: 'Far', all_day: false }.merge(parts(day))
          expect_refused('Start date', 'End date')
        end
        expect(Event.count).to eq(0)

        post '/api/v1/events', params: { token: token, title: 'Near', all_day: false }.merge(parts(inside))
        expect(response).to have_http_status(:ok)
      end

      it 'refuses a new all-day one' do
        post '/api/v1/events', params: { token: token, title: 'Far', all_day: true }.merge(parts(too_far))

        expect_refused('Start date')
      end

      it 'refuses to move one out, and leaves it as it was' do
        event = create(:event, community: community)
        before = event.reload.attributes

        patch "/api/v1/events/#{event.id}/update",
              params: { token: token, title: 'Moved', all_day: false }.merge(parts(too_far))

        expect_refused('Start date', 'End date')
        expect(event.reload.attributes).to eq(before)
      end
    end

    describe 'a Common House booking' do
      it 'refuses a new one at either end' do
        [too_old, too_far].each do |day|
          post '/api/v1/common-house-reservations',
               params: { token: token, resident_id: resident.id, title: 'Far' }.merge(parts(day))
          expect_refused('Start date', 'End date')
        end
        expect(CommonHouseReservation.count).to eq(0)
      end

      it 'refuses to move one out, and leaves it as it was' do
        booking = create(:common_house_reservation, community: community, resident: resident)
        before = booking.reload.attributes

        patch "/api/v1/common-house-reservations/#{booking.id}/update",
              params: { token: token, resident_id: resident.id, title: 'Moved' }.merge(parts(too_old))

        expect_refused('Start date', 'End date')
        expect(booking.reload.attributes).to eq(before)
      end
    end

    describe 'a guest room booking' do
      it 'refuses a new one at either end' do
        [too_old, too_far].each do |day|
          post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: day.iso8601 }
          expect_refused('Date')
        end
        expect(GuestRoomReservation.count).to eq(0)
      end

      it 'refuses to move one out, and leaves it as it was' do
        booking = create(:guest_room_reservation, community: community, resident: resident, date: inside)
        before = booking.reload.attributes

        patch "/api/v1/guest-room-reservations/#{booking.id}/update",
              params: { token: token, resident_id: resident.id, date: too_far.iso8601 }

        expect_refused('Date')
        expect(booking.reload.attributes).to eq(before)
      end
    end
  end

  describe 'admin' do
    let(:admin_user) { create(:admin_user, community: community, superuser: true) }

    before do
      host! 'admin.example.com'
      sign_in admin_user
    end

    # ActiveAdmin shows the form again as a 200, with each field's error
    # under that field.
    def field_error(form, field)
      expect(response).to have_http_status(:ok)
      response.parsed_body.at_css("##{form}_#{field}_input .inline-errors")&.text
    end

    # The five menus of a time (year, month, day, hour, minute), the way
    # the event and Common House forms name them.
    def menus(field, day, hour)
      [day.year, day.month, day.day, hour, 0].each_with_index.to_h { |value, index| ["#{field}(#{index + 1}i)", value] }
    end

    def times(day) = menus('start_date', day, 18).merge(menus('end_date', day, 19))

    it 'refuses a new event, and says so under each time' do
      post '/events', params: { event: times(too_far).merge('title' => 'Far') }

      expect(field_error('event', 'start_date')).to eq(words)
      expect(field_error('event', 'end_date')).to eq(words)
      expect(Event.count).to eq(0)
    end

    it 'refuses a new Common House booking, and says so under each time' do
      post '/common_house_reservations',
           params: { common_house_reservation: times(too_old).merge('resident_id' => resident.id, 'title' => 'Far') }

      expect(field_error('common_house_reservation', 'start_date')).to eq(words)
      expect(CommonHouseReservation.count).to eq(0)
    end

    it 'refuses a new guest room booking, and to move one out' do
      post '/guest_room_reservations',
           params: { guest_room_reservation: { resident_id: resident.id, date: too_far.iso8601 } }
      expect(field_error('guest_room_reservation', 'date')).to eq(words)

      booking = create(:guest_room_reservation, community: community, resident: resident, date: inside)
      patch "/guest_room_reservations/#{booking.id}", params: { guest_room_reservation: { date: too_old.iso8601 } }
      expect(field_error('guest_room_reservation', 'date')).to eq(words)
      expect(booking.reload.date).to eq(inside)
    end

    describe 'a dinner' do
      let(:rotation) { create(:rotation, community: community) }

      it 'refuses a new one more than 10 years back' do
        post '/meals', params: { meal: { date: too_old.iso8601, closed: '0', rotation_id: rotation.id } }

        expect(field_error('meal', 'date')).to eq(words)
        expect(Meal.count).to eq(0)
      end

      # Before 2026-11-15 a meal had no storable_time rule, and its
      # uniqueness check sent the day to PostgreSQL, which raised
      # PG::DatetimeFieldOverflow: an error page, not the form.
      it 'refuses a day the database cannot store with the form, not an error page' do
        post '/meals', params: { meal: { date: '5874898-01-01', closed: '0', rotation_id: rotation.id } }

        expect(field_error('meal', 'date')).to eq('is not a date the database can store')
        expect(Meal.count).to eq(0)
      end
    end
  end
end

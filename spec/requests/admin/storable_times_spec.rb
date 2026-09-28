# frozen_string_literal: true

require 'rails_helper'

# PostgreSQL cannot store a time before midnight UTC on November 24,
# 4714 BC or after the end of 294276 (StorableTime). The event and
# common house forms send each time as five menus, and the year menu
# offers only years near today, but a request can carry any year. A year like 300000 raised
# PG::DatetimeFieldOverflow when the record was saved: an error page
# instead of the form. The API refuses these times in its own parser
# (events_controller_spec.rb); this is the admin side of the same
# records.
RSpec.describe 'Admin forms and a time the database cannot store' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:refused) { 'is not a date the database can store' }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # The five menus of the start and of the end (year, month, day, hour,
  # minute), the way the form names them.
  def times(start, finish)
    { 'start_date' => start, 'end_date' => finish }.flat_map do |field, parts|
      parts.each_with_index.map { |value, index| ["#{field}(#{index + 1}i)", value.to_s] }
    end.to_h
  end

  # ActiveAdmin shows the form again as a 200, with each field's error
  # under that field.
  def field_errors(form)
    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    %w[start_date end_date].index_with { |field| page.at_css("##{form}_#{field}_input .inline-errors")&.text }
  end

  describe 'event' do
    it 'refuses a new event in the year 300000 or 5000 BC, and says so under each time' do
      [300_000, -4999].each do |year|
        post '/events', params: { event: times([year, 4, 12, 18, 0], [year, 4, 12, 19, 0]).merge('title' => 'Far') }

        expect(field_errors('event')).to eq('start_date' => refused, 'end_date' => refused)
      end
      expect(Event.count).to eq(0)
    end

    # 16:00 on the last day in Los Angeles is already 294277 in UTC.
    it 'refuses to move an event past the last instant, and leaves it as it was' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 4, 10, 18),
                             end_date: Time.zone.local(2026, 4, 10, 21))
      before = event.reload.attributes

      patch "/events/#{event.id}", params: { event: times([294_276, 12, 31, 15, 0], [294_276, 12, 31, 16, 0]) }

      expect(field_errors('event')).to eq('start_date' => nil, 'end_date' => refused)
      expect(event.reload.attributes).to eq(before)
    end
  end

  describe 'common house' do
    it 'refuses a new booking in the year 300000, and says so under each time' do
      far = times([300_000, 4, 12, 18, 0], [300_000, 4, 12, 19, 0])
      post '/common_house_reservations', params: { common_house_reservation: far.merge('resident_id' => resident.id) }

      expect(field_errors('common_house_reservation')).to eq('start_date' => refused, 'end_date' => refused)
      expect(CommonHouseReservation.count).to eq(0)
    end

    # 16:07 on November 23, 4714 BC in Los Angeles, which kept local mean
    # time then (7:52:58 behind UTC), is two seconds before the first
    # instant; 17:00 is after it.
    it 'refuses to move a booking before the first instant, and leaves it as it was' do
      booking = create(:common_house_reservation, community: community, resident: resident,
                                                  start_date: Time.zone.local(2026, 4, 10, 18),
                                                  end_date: Time.zone.local(2026, 4, 10, 21))
      before = booking.reload.attributes

      patch "/common_house_reservations/#{booking.id}",
            params: { common_house_reservation: times([-4713, 11, 23, 16, 7], [-4713, 11, 23, 17, 0]) }

      expect(field_errors('common_house_reservation')).to eq('start_date' => refused, 'end_date' => nil)
      expect(booking.reload.attributes).to eq(before)
    end
  end

  # The guest room form takes its day as text. A date column holds days
  # up to December 31, 5874897, and only days of the Gregorian calendar,
  # which has no February 29, 1500.
  describe 'guest room' do
    it 'refuses a day the database cannot store, and says so under the date' do
      %w[5874898-01-01 1500-02-29].each do |date|
        post '/guest_room_reservations', params: { guest_room_reservation: { resident_id: resident.id, date: date } }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.at_css('#guest_room_reservation_date_input .inline-errors')&.text).to eq(refused)
      end
      expect(GuestRoomReservation.count).to eq(0)
    end
  end
end

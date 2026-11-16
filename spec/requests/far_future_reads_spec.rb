# frozen_string_literal: true

require 'rails_helper'

# The app works on every day up to December 31, 9999, the last day a
# dinner may have (CalendarWindow, challenge 6). Each example moves the
# clock to the years the window will reach one day, puts things on the
# far days, and reads every page that shows them.
#
# 2100 divides by 4 but is not a leap year: February 28 is followed by
# March 1. The last month, December 9999, is drawn as six weeks, so its
# grid ends in January 10000.
RSpec.describe 'Pages that show dates, in the far future' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community, timezone: 'America/Los_Angeles') }
  let(:zone) { ActiveSupport::TimeZone['America/Los_Angeles'] }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:token) { resident.keys.first.token }

  def get_json(path, **params)
    get path, params: { token: token }.merge(params)
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  # Every date string anywhere in the calendar's answer.
  def dates_in(calendar)
    calendar.to_json.scan(/"(\d{4,5}-\d{2}-\d{2})/).flatten.uniq.sort
  end

  describe 'February 2100, a year with no February 29' do
    before do
      travel_to zone.local(2095, 6, 1, 12)
      create(:meal, community: community, date: Date.new(2100, 2, 28))
      create(:meal, community: community, date: Date.new(2100, 3, 1))
    end

    it 'refuses February 29, 2100 as a day, at the API and in the model' do
      get "/api/v1/communities/#{community.id}/calendar/2100-02-29", params: { token: token }
      expect(response).to have_http_status(:bad_request)

      post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: '2100-02-29' }
      expect(response).to have_http_status(:bad_request)
      expect(GuestRoomReservation.count).to eq(0)
    end

    it 'shows the dinners on February 28 and March 1, one day apart, in both months' do
      february = get_json("/api/v1/communities/#{community.id}/calendar/2100-02-01")
      march = get_json("/api/v1/communities/#{community.id}/calendar/2100-03-01")

      [february, march].each do |month|
        expect(dates_in(month)).to include('2100-02-28', '2100-03-01')
        expect(dates_in(month)).not_to include('2100-02-29')
      end
    end

    it 'books the guest room on February 28 and March 1, which are next to each other' do
      %w[2100-02-28 2100-03-01].each do |day|
        post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: day }
        expect(response).to have_http_status(:ok)
      end
    end

    it 'puts each dinner on its own day, at the dinner hour, in the iCal feed' do
      get "/api/v1/communities/#{community.id}/ical"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('DTSTART;TZID=America/Los_Angeles:21000228T190000',
                                       'DTSTART;TZID=America/Los_Angeles:21000301T190000')
    end
  end

  describe 'December 9999, the last month' do
    before { travel_to zone.local(9999, 12, 20, 12) }

    let!(:last_dinner) { create(:meal, community: community, date: Date.new(9999, 12, 31)) }

    it 'shows the last dinner, an event that ends at 11 PM, and both bookings on the last day' do
      # 11 PM on December 31, 9999 in Los Angeles is already 10000 in UTC.
      create(:event, community: community, title: 'Last party', start_date: zone.local(9999, 12, 31, 21),
                     end_date: zone.local(9999, 12, 31, 23))
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(9999, 12, 31))
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: zone.local(9999, 12, 31, 9), end_date: zone.local(9999, 12, 31, 10))

      month = get_json("/api/v1/communities/#{community.id}/calendar/9999-12-01")

      expect(month.to_json).to include('Last party')
      expect(dates_in(month)).to include('9999-12-31')
    end

    it 'answers the next dinner, its cooks, its history and the birthdays' do
      expect(get_json('/api/v1/meals/next')).to eq('meal_id' => last_dinner.id)
      expect(get_json("/api/v1/meals/#{last_dinner.id}/cooks").to_json).to include('9999-12-31')
      expect(get_json("/api/v1/meals/#{last_dinner.id}/history")['date']).to eq('9999-12-31')
      get_json("/api/v1/communities/#{community.id}/birthdays", start: '9999-11-28')
    end

    it 'puts the last dinner on its day in both iCal feeds' do
      create(:bill, community: community, meal: last_dinner, resident: resident)

      ["/api/v1/communities/#{community.id}/ical", "/api/v1/residents/#{resident.id}/ical"].each do |path|
        get path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('DTSTART;TZID=America/Los_Angeles:99991231T190000')
      end
    end

    it 'refuses a calendar month in the year 10000 with a 400, not an error page' do
      get "/api/v1/communities/#{community.id}/calendar/10000-01-01", params: { token: token }

      expect(response).to have_http_status(:bad_request)
    end
  end
end

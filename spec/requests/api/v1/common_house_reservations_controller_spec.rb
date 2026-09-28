# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Common House Reservations API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/common-house-reservations/:id' do
    # Before #103 show rendered the record itself, not a serializer, so
    # every column went out, community_id and the timestamps included.
    # Residents are served by CommunitiesController#hosts, not inlined here.
    it 'returns, under "event", the fields the edit form reads, value by value, and no other column' do
      chr = create(:common_house_reservation, community: community, resident: resident, title: 'Book club',
                                              start_date: Time.zone.local(2026, 9, 5, 19, 0),
                                              end_date: Time.zone.local(2026, 9, 5, 21, 0))

      get "/api/v1/common-house-reservations/#{chr.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'event' => { 'id' => chr.id, 'resident_id' => resident.id, 'title' => 'Book club',
                     'start_date' => '2026-09-05T19:00:00.000-07:00', 'end_date' => '2026-09-05T21:00:00.000-07:00' }
      )
    end

    it 'sends a reservation with no title as null' do
      chr = create(:common_house_reservation, community: community, resident: resident, title: nil)

      get "/api/v1/common-house-reservations/#{chr.id}", params: { token: token }

      expect(response.parsed_body['event']).to include('title' => nil)
    end

    it 'returns 404 for nonexistent reservation' do
      get '/api/v1/common-house-reservations/999999', params: { token: token }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/common-house-reservations' do
    it 'creates a reservation' do
      post '/api/v1/common-house-reservations', params: {
        token: token,
        resident_id: resident.id, title: 'Birthday party',
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 14, start_minutes: 0,
        end_hours: 17, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      expect(CommonHouseReservation.count).to eq(1)
      expect(CommonHouseReservation.last.title).to eq('Birthday party')
    end

    it 'returns 400 for a month that does not exist' do
      post '/api/v1/common-house-reservations', params: {
        token: token,
        resident_id: resident.id, title: 'Never',
        start_year: 2026, start_month: 13, start_day: 1,
        start_hours: 14, start_minutes: 0,
        end_hours: 17, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
      expect(CommonHouseReservation.count).to eq(0)
    end

    # Before #102 the parser rolled February 30 over to March 2 and saved
    # the reservation there.
    it 'returns 400 for a day that does not exist in its month' do
      post '/api/v1/common-house-reservations', params: {
        token: token,
        resident_id: resident.id, title: 'Never',
        start_year: 2026, start_month: 2, start_day: 30,
        start_hours: 14, start_minutes: 0,
        end_hours: 17, end_minutes: 0
      }

      expect(CommonHouseReservation.pluck(:start_date, :end_date)).to eq([])
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
    end

    # Before #102 a blank hour was read as 0, so a reservation with no
    # times was saved from midnight to midnight. A blank start with a real
    # end was saved from midnight too.
    it 'refuses a reservation with no times, the way the form sends it when both time menus are empty' do
      [{ start_hours: '', start_minutes: '', end_hours: '', end_minutes: '' },
       { start_hours: '', start_minutes: '', end_hours: 17, end_minutes: 0 }].each do |times|
        post '/api/v1/common-house-reservations', params: {
          token: token,
          resident_id: resident.id, title: 'No times',
          start_year: 2026, start_month: 5, start_day: 1
        }.merge(times)

        expect(CommonHouseReservation.pluck(:start_date, :end_date)).to eq([])
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body['message']).to eq('Error: Invalid date')
      end
    end

    it 'rejects overlapping reservations in the same community' do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 5, 1, 14, 0),
                                        end_date: Time.zone.local(2026, 5, 1, 17, 0))

      post '/api/v1/common-house-reservations', params: {
        token: token,
        resident_id: resident.id, title: 'Conflict',
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 15, start_minutes: 0,
        end_hours: 18, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'PATCH /api/v1/common-house-reservations/:id/update' do
    it 'updates the reservation' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
        token: token, resident_id: resident.id, title: 'Updated',
        start_year: 2026, start_month: 6, start_day: 1,
        start_hours: 10, start_minutes: 0,
        end_hours: 12, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      expect(chr.reload.title).to eq('Updated')
    end

    # Regression test for BUG-3: update lacked the begin/rescue that create has.
    it 'refuses to move a reservation onto another one, and says so' do
      taken = Time.zone.local(2026, 5, 2, 14, 0)
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: taken, end_date: taken + 2.hours)
      moving = create(:common_house_reservation, community: community, resident: resident,
                                                 start_date: taken + 5.hours, end_date: taken + 6.hours)

      patch "/api/v1/common-house-reservations/#{moving.id}/update", params: {
        token: token,
        resident_id: resident.id, title: 'Moved',
        start_year: 2026, start_month: 5, start_day: 2,
        start_hours: 15, start_minutes: 0,
        end_hours: 16, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Time period is already taken')
      expect(moving.reload.title).not_to eq('Moved')
    end

    # The same parser as create (#102).
    it 'refuses February 30 and blank times, and leaves the reservation as it was' do
      chr = create(:common_house_reservation, community: community, resident: resident)
      before = chr.reload.attributes

      [{ start_day: 30, start_hours: 10, start_minutes: 0, end_hours: 12, end_minutes: 0 },
       { start_day: 1, start_hours: '', start_minutes: '', end_hours: '', end_minutes: '' }].each do |changed|
        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
          token: token, resident_id: resident.id, title: 'Moved', start_year: 2026, start_month: 2
        }.merge(changed)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Error: Invalid date')
        expect(chr.reload.attributes).to eq(before)
      end
    end

    it 'returns 400 for invalid date params instead of 500' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
        token: token, resident_id: resident.id, title: 'Bad date',
        start_year: 2026, start_month: 13, start_day: 1,
        start_hours: 10, start_minutes: 0,
        end_hours: 12, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid date')
    end
  end

  describe 'DELETE /api/v1/common-house-reservations/:id/delete' do
    it 'deletes the reservation' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      expect do
        delete "/api/v1/common-house-reservations/#{chr.id}/delete", params: { token: token }
      end.to change(CommonHouseReservation, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end
end

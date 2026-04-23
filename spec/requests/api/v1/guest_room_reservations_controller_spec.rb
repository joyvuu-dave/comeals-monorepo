# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Guest Room Reservations API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/guest-room-reservations' do
    it 'returns reservations for the community' do
      create(:guest_room_reservation, community: community, resident: resident)

      get '/api/v1/guest-room-reservations', params: { community_id: community.id, token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.length).to eq(1)
    end

    it 'filters by date range' do
      create(:guest_room_reservation, community: community, resident: resident,
                                      date: 1.year.ago.to_date)
      create(:guest_room_reservation, community: community, resident: resident,
                                      date: Date.yesterday)

      get '/api/v1/guest-room-reservations', params: {
        community_id: community.id, token: token,
        start: 1.week.ago.to_date.to_s, end: Time.zone.today.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.length).to eq(1)
    end

    it 'returns 401 without a token' do
      get '/api/v1/guest-room-reservations', params: { community_id: community.id }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/guest-room-reservations/:id' do
    it 'returns the reservation event' do
      grr = create(:guest_room_reservation, community: community, resident: resident)

      get "/api/v1/guest-room-reservations/#{grr.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to have_key('event')
      # Hosts are served by CommunitiesController#hosts, not inlined here.
      expect(body).not_to have_key('hosts')
    end

    it 'returns 404 for nonexistent reservation' do
      get '/api/v1/guest-room-reservations/999999', params: { token: token }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/guest-room-reservations' do
    it 'creates a reservation' do
      post '/api/v1/guest-room-reservations', params: {
        community_id: community.id, token: token,
        resident_id: resident.id, date: Date.tomorrow.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(GuestRoomReservation.count).to eq(1)
    end

    it 'rejects duplicate date for same community' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.tomorrow)

      post '/api/v1/guest-room-reservations', params: {
        community_id: community.id, token: token,
        resident_id: resident.id, date: Date.tomorrow.to_s
      }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'PATCH /api/v1/guest-room-reservations/:id/update' do
    it 'updates the reservation' do
      grr = create(:guest_room_reservation, community: community, resident: resident)

      patch "/api/v1/guest-room-reservations/#{grr.id}/update", params: {
        token: token, date: (Time.zone.today + 10).to_s, resident_id: resident.id
      }

      expect(response).to have_http_status(:ok)
      expect(grr.reload.date).to eq(Time.zone.today + 10)
    end
  end

  describe 'DELETE /api/v1/guest-room-reservations/:id/delete' do
    it 'deletes the reservation' do
      grr = create(:guest_room_reservation, community: community, resident: resident)

      expect do
        delete "/api/v1/guest-room-reservations/#{grr.id}/delete", params: { token: token }
      end.to change(GuestRoomReservation, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Guest Room Reservations API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/guest-room-reservations/:id' do
    # Before #103 show rendered the record itself, not a serializer, so
    # every column went out, community_id and the timestamps included.
    # Hosts are served by CommunitiesController#hosts, not inlined here.
    it 'returns, under "event", the fields the edit form reads, value by value, and no other column' do
      grr = create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 9, 5))

      get "/api/v1/guest-room-reservations/#{grr.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('event' => { 'id' => grr.id, 'resident_id' => resident.id,
                                                      'date' => '2026-09-05' })
    end

    it 'returns 404 for nonexistent reservation' do
      get '/api/v1/guest-room-reservations/999999', params: { token: token }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/guest-room-reservations' do
    it 'creates a reservation' do
      post '/api/v1/guest-room-reservations', params: {
        token: token,
        resident_id: resident.id, date: Date.tomorrow.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(GuestRoomReservation.count).to eq(1)
    end

    it 'rejects duplicate date for same community' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.tomorrow)

      post '/api/v1/guest-room-reservations', params: {
        token: token,
        resident_id: resident.id, date: Date.tomorrow.to_s
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Date has already been taken')
    end

    it 'lists every problem, one per line, when there is more than one' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 1))

      post '/api/v1/guest-room-reservations',
           params: { token: token, resident_id: 0, date: '2026-06-01' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => "Resident must exist\nDate has already been taken")
    end
  end

  # PostgreSQL stores a date from November 24, 4714 BC (Ruby's year
  # -4713, because Ruby counts 1 BC as year 0) to December 31, 5874897,
  # in the Gregorian calendar carried back before 1582. A day outside
  # that, or a day only the Julian calendar has, like February 29, 1500,
  # raised PG::DatetimeFieldOverflow in the check for a taken day: a 500.
  describe 'a day the database cannot store' do
    let(:refused) { 'Date is not a date the database can store' }

    it 'is refused on create at both ends and for a Julian leap day, and the day next to each is taken' do
      answers = %w[5874898-01-01 5874897-12-31 -4713-11-23 -4713-11-24 1500-02-29 1600-02-29].index_with do |date|
        post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: date }
        [response.status, response.parsed_body['message']]
      end

      created = [200, 'Guest Room Reservation has been created']
      expect(answers).to eq('5874898-01-01' => [400, refused], '5874897-12-31' => created,
                            '-4713-11-23' => [400, refused], '-4713-11-24' => created,
                            '1500-02-29' => [400, refused], '1600-02-29' => created)
      expect(GuestRoomReservation.order(:id).pluck(:date).map(&:iso8601))
        .to eq(%w[5874897-12-31 -4713-11-24 1600-02-29])
    end

    it 'is refused on update, and the booking stays where it was' do
      grr = create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 2))

      patch "/api/v1/guest-room-reservations/#{grr.id}/update",
            params: { token: token, resident_id: resident.id, date: '99999999-01-01' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => refused)
      expect(grr.reload.date).to eq(Date.new(2026, 6, 2))
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

  describe 'PATCH to a date that is already taken' do
    it 'is refused with the reason' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 1))
      moving = create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 2))

      patch "/api/v1/guest-room-reservations/#{moving.id}/update",
            params: { token: token, resident_id: resident.id, date: '2026-06-01' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Date has already been taken')
      expect(moving.reload.date).to eq(Date.new(2026, 6, 2))
    end

    it 'lists every problem, one per line, when there is more than one' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 1))
      moving = create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 6, 2))

      patch "/api/v1/guest-room-reservations/#{moving.id}/update",
            params: { token: token, resident_id: 0, date: '2026-06-01' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("Resident must exist\nDate has already been taken")
      expect(moving.reload).to have_attributes(date: Date.new(2026, 6, 2), resident_id: resident.id)
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

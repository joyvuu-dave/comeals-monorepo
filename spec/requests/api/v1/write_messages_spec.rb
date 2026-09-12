# frozen_string_literal: true

require 'rails_helper'

# What each write answers. The SPA shows some of these words and reads
# the rest as "it worked", so the exact body is part of the contract:
# a write that answers nothing, or the wrong words, passed every status
# check before this.
RSpec.describe 'API write responses' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: community.today + 3) }

  describe 'meals' do
    it 'answers each attendance and meal write with its own sentence' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: false, vegetarian: false }
      expect(response).to have_http_status(:ok)

      patch "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: true, vegetarian: false }
      expect(response.parsed_body).to eq('message' => 'MealResident updated.')

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token }
      expect(response.parsed_body).to eq('message' => 'MealResident destroyed.')

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: { token: token, vegetarian: false }
      guest_id = response.parsed_body.fetch('id')
      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest_id}", params: { token: token }
      expect(response.parsed_body).to eq('message' => 'Guest was destroyed.')

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Pasta' }
      expect(response.parsed_body).to eq('message' => 'Description updated.')

      patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: true }
      expect(response.parsed_body).to eq('message' => 'Meal closed value updated.')

      patch "/api/v1/meals/#{meal.id}/max", params: { token: token, max: 10 }
      expect(response.parsed_body).to eq('message' => 'Meal max value updated.')
    end

    it 'names the meal that is next by date, not by the order the meals were made' do
      later = create(:meal, community: community, date: community.today + 9)
      sooner = create(:meal, community: community, date: community.today + 2)

      get '/api/v1/meals/next', params: { token: token }

      expect(response.parsed_body).to eq('meal_id' => sooner.id)
      expect(later).to be_persisted
    end

    it 'dates the history by the meal' do
      get "/api/v1/meals/#{meal.id}/history", params: { token: token }

      expect(response.parsed_body).to include('date' => meal.date.iso8601)
      expect(response.parsed_body.fetch('items')).to be_an(Array)
    end

    it 'leaves the sender\'s own socket out of the meal push' do
      allow(Pusher).to receive(:trigger)

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Pasta', socket_id: 'me' }

      expect(Pusher).to have_received(:trigger).with("meal-#{meal.id}", 'update', anything, { socket_id: 'me' })
    end
  end

  describe 'events' do
    it 'answers create, update and delete each with its own sentence' do
      post '/api/v1/events', params: { token: token, title: 'Movie Night', description: 'Popcorn', all_day: false,
                                       start_year: 2026, start_month: 4, start_day: 15, start_hours: 19,
                                       start_minutes: 0, end_hours: 21, end_minutes: 30 }
      expect(response.parsed_body).to eq('message' => 'Event has been created')
      event = Event.last

      patch "/api/v1/events/#{event.id}/update", params: { token: token, title: 'Movie Night', description: 'Popcorn',
                                                           all_day: false, start_year: 2026, start_month: 4,
                                                           start_day: 16, start_hours: 19, start_minutes: 0,
                                                           end_hours: 21, end_minutes: 30 }
      expect(response.parsed_body).to eq('message' => 'Event has been updated')

      get "/api/v1/events/#{event.id}", params: { token: token }
      expect(response.parsed_body).to include('id' => event.id, 'title' => 'Movie Night')

      delete "/api/v1/events/#{event.id}/delete", params: { token: token }
      expect(response.parsed_body).to eq('message' => 'Event has been removed')
    end
  end

  describe 'common house reservations' do
    it 'answers create, update and delete each with its own sentence, and shows the booking' do
      post '/api/v1/common-house-reservations', params: { token: token, resident_id: resident.id, title: 'Book club',
                                                          start_year: 2026, start_month: 4, start_day: 15,
                                                          start_hours: 14, start_minutes: 0, end_hours: 16,
                                                          end_minutes: 0 }
      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been created')
      reservation = CommonHouseReservation.last

      patch "/api/v1/common-house-reservations/#{reservation.id}/update",
            params: { token: token, resident_id: resident.id, title: 'Book club', start_year: 2026, start_month: 4,
                      start_day: 16, start_hours: 14, start_minutes: 0, end_hours: 16, end_minutes: 0 }
      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')

      get "/api/v1/common-house-reservations/#{reservation.id}", params: { token: token }
      expect(response.parsed_body.fetch('event')).to include('id' => reservation.id, 'title' => 'Book club')

      delete "/api/v1/common-house-reservations/#{reservation.id}/delete", params: { token: token }
      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been removed')
    end
  end

  describe 'guest room reservations' do
    it 'answers create, update and delete each with its own sentence, and shows the booking' do
      post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: '2026-04-15' }
      expect(response.parsed_body).to eq('message' => 'Guest Room Reservation has been created')
      reservation = GuestRoomReservation.last

      other = create(:resident, community: community, unit: unit)
      patch "/api/v1/guest-room-reservations/#{reservation.id}/update",
            params: { token: token, resident_id: other.id, date: '2026-04-16' }
      expect(response.parsed_body).to eq('message' => 'Guest Room Reservation has been updated')
      expect(reservation.reload).to have_attributes(resident_id: other.id, date: Date.new(2026, 4, 16))

      get "/api/v1/guest-room-reservations/#{reservation.id}", params: { token: token }
      expect(response.parsed_body.fetch('event')).to include('id' => reservation.id)

      delete "/api/v1/guest-room-reservations/#{reservation.id}/delete", params: { token: token }
      expect(response.parsed_body).to eq('message' => 'Guest Room Reservation has been removed')
    end
  end
end

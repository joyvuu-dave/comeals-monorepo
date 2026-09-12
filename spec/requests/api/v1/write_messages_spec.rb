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

    it 'treats a blank socket id as no sender' do
      allow(Pusher).to receive(:trigger)

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Pasta', socket_id: '' }

      expect(Pusher).to have_received(:trigger).with("meal-#{meal.id}", 'update', anything).at_least(:once)
      expect(Pusher).not_to have_received(:trigger).with("meal-#{meal.id}", 'update', anything, { socket_id: '' })
    end

    it 'says there is no next meal with a null id' do
      get '/api/v1/meals/next', params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('meal_id' => nil)
    end

    it 'refuses a write on a settled meal before taking the lock, in one sentence' do
      meal.update!(reconciliation: create(:reconciliation, community: community))

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Pasta' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Change not permitted. Meal has already been reconciled.')
    end
  end

  describe 'the community zone around every API request' do
    # The wrapper is what makes "19:00" mean 19:00 where the community
    # is. Without it a Tokyo dinner is stored at 19:00 Pacific.
    it 'reads the hours of a new event in the community zone, signed in by token or by header' do
      community.update!(timezone: 'Asia/Tokyo')
      event_params = { title: 'Movie Night', all_day: false, start_year: 2026, start_month: 4, start_day: 15,
                       start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 0 }

      post '/api/v1/events', params: event_params.merge(token: token)
      expect(response).to have_http_status(:ok)
      expect(Event.last.start_date.utc).to eq(Time.utc(2026, 4, 15, 10, 0))

      post '/api/v1/events', params: event_params.merge(start_day: 16),
                             headers: { 'Authorization' => "Bearer #{JwtAuth.encode(resident)}" }
      expect(response).to have_http_status(:ok)
      expect(Event.last.start_date.utc).to eq(Time.utc(2026, 4, 16, 10, 0))
    end
  end

  describe 'the calendar month' do
    it 'covers the six weeks from the Sunday before the 1st, and names the month those weeks show most of' do
      [Date.new(2026, 3, 28), Date.new(2026, 3, 29), Date.new(2026, 5, 9), Date.new(2026, 5, 10)].each do |date|
        create(:meal, community: community, date: date)
      end

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

      body = response.parsed_body
      expect(body.values_at('month', 'year')).to eq([4, 2026])
      expect(body.fetch('meals').map { |chip| chip.fetch('start')[0, 10] })
        .to contain_exactly('2026-03-29', '2026-05-09')
    end

    it 'leaves retired residents out of the birthdays' do
      april = create(:resident, community: community, unit: unit, birthday: Date.new(1990, 4, 15))
      create(:resident, community: community, unit: unit, birthday: Date.new(1991, 4, 16), active: false,
                        can_cook: false, email: nil)

      get "/api/v1/communities/#{community.id}/birthdays", params: { token: token, start: '2026-03-29' }

      expect(response.parsed_body.pluck('id')).to eq([april.cache_key_with_version])
    end
  end

  describe 'the answers every API action shares' do
    it 'names a missing record in one sentence' do
      get '/api/v1/events/999999', params: { token: token }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq('message' => "The page you were looking for doesn't exist. You may have " \
                                                      'mistyped the address or the page may have moved.')
    end

    it 'names a missing sign-in in one sentence' do
      get "/api/v1/meals/#{meal.id}/history"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('message' => 'You are not authenticated. Please try signing in and then ' \
                                                      'try again.')
    end
  end

  describe 'the community' do
    it 'lists hosts by unit name, with the unit name beside each' do
      last_unit = create(:unit, community: community, name: 'Z9')
      first_unit = create(:unit, community: community, name: 'A1')
      late = create(:resident, community: community, unit: last_unit, multiplier: 2, name: 'Zed Young')
      early = create(:resident, community: community, unit: first_unit, multiplier: 2, name: 'Abe Old')

      get "/api/v1/communities/#{community.id}/hosts", params: { token: token }

      expect(response.parsed_body.first).to eq([early.id, 'Abe Old', 'A1'])
      expect(response.parsed_body.last).to eq([late.id, 'Zed Young', 'Z9'])
    end

    it 'takes the birthdays of the month two weeks after the start of the six-week grid' do
      april = create(:resident, community: community, unit: unit, birthday: Date.new(1990, 4, 15))
      create(:resident, community: community, unit: unit, birthday: Date.new(1990, 3, 15))

      get "/api/v1/communities/#{community.id}/birthdays", params: { token: token, start: '2026-03-29' }

      expect(response.parsed_body.pluck('id')).to eq([april.cache_key_with_version])
    end

    it 'links each dinner in the feed to its page under the configured root' do
      dinner = create(:meal, community: community, date: Date.new(2026, 4, 10), description: 'Soup night')

      get "/api/v1/communities/#{community.id}/ical"

      unfolded = response.body.gsub(/\r?\n[ \t]/, '')
      expect(unfolded).to include('SUMMARY:Common Dinner')
      expect(unfolded).to include('DESCRIPTION:Soup night\\n\\n\\n\\nSign up here: ' \
                                  "http://localhost:3036/meals/#{dinner.id}/edit")
    end
  end

  describe 'residents' do
    it 'finds the resident by email with spaces trimmed and case ignored' do
      resident.update!(email: 'sarah@example.com', password: 'secret123')

      post '/api/v1/residents/token', params: { email: '  Sarah@Example.com  ', password: 'secret123' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('resident_id' => resident.id)
    end

    it 'shortens the name on the reset page, with the last initial when first names clash' do
      resident.update!(name: 'Sarah Connor', reset_password_token: 'tok', reset_password_sent_at: Time.current)
      create(:resident, community: community, unit: unit, name: 'Sarah Lee')

      get '/api/v1/residents/name/tok'

      expect(response.parsed_body).to eq('name' => 'Sarah C')
    end

    it 'answers a reset with an unknown token in one word' do
      post '/api/v1/residents/password-reset/no-such-token', params: { password: 'new-secret' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Error.')
    end

    it 'names the email it could not find' do
      post '/api/v1/residents/token', params: { email: 'nobody@example.com', password: 'x' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'No resident with email nobody@example.com')
    end

    it 'clears an expired reset token when someone tries to use it' do
      resident.update!(reset_password_token: 'old', reset_password_sent_at: 3.days.ago)

      post '/api/v1/residents/password-reset/old', params: { password: 'new-secret' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Password reset link has expired. Please request a new one.')
      expect(resident.reload).to have_attributes(reset_password_token: nil, reset_password_sent_at: nil)
    end

    it 'links each cook slot in the feed to its meal page under the configured root' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 10), description: 'Soup night')
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('10'))

      get "/api/v1/residents/#{resident.id}/ical"

      unfolded = response.body.gsub(/\r?\n[ \t]/, '')
      expect(unfolded).to include('SUMMARY:Cook Common Dinner')
      expect(unfolded).to include('DESCRIPTION:Soup night\\n\\n\\n\\nView here: ' \
                                  "http://localhost:3036/meals/#{meal.id}/edit")
    end

    it 'puts only the resident\'s own cook slots in their feed' do
      other = create(:resident, community: community, unit: unit, multiplier: 2)
      mine = create(:meal, community: community, date: Date.new(2026, 4, 10))
      theirs = create(:meal, community: community, date: Date.new(2026, 4, 17))
      create(:bill, meal: mine, resident: resident, community: community, amount: BigDecimal('10'))
      create(:bill, meal: theirs, resident: other, community: community, amount: BigDecimal('10'))

      get "/api/v1/residents/#{resident.id}/ical"

      expect(response.body).to include('20260410')
      expect(response.body).not_to include('20260417')
    end
  end

  describe 'events' do
    it 'keeps an all-day event all day when an update does not mention it' do
      event = create(:event, community: community, title: 'Work Day', allday: true, end_date: nil,
                             start_date: Time.zone.local(2026, 4, 16, 0, 0))

      patch "/api/v1/events/#{event.id}/update", params: { token: token, title: 'Big Work Day', start_year: 2026,
                                                           start_month: 4, start_day: 16 }

      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(title: 'Big Work Day', allday: true)
    end

    it 'stores an empty description when none is sent' do
      post '/api/v1/events', params: { token: token, title: 'Quiet Hour', all_day: true, start_year: 2026,
                                       start_month: 4, start_day: 16 }

      expect(response).to have_http_status(:ok)
      expect(Event.last.description).to eq('')
    end

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

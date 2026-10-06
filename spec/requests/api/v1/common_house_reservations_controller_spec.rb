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

    # People post notices this way ("Movie night is cancelled tonight").
    # The form sends '' for each part of an empty time menu; a direct API
    # call may leave the parts out. Midnight exists on both daylight saving
    # days in the community's zone, so those days get midnight too.
    it 'saves a reservation with both time menus empty from midnight to midnight' do
      days = [[2026, 5, 1], [2026, 3, 8], [2026, 11, 1]]
      days.each do |year, month, day|
        post '/api/v1/common-house-reservations', params: {
          token: token, resident_id: resident.id, title: 'Movie night is cancelled tonight',
          start_year: year, start_month: month, start_day: day,
          start_hours: '', start_minutes: '', end_hours: '', end_minutes: ''
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been created')
      end
      post '/api/v1/common-house-reservations', params: {
        token: token, resident_id: resident.id, start_year: 2026, start_month: 5, start_day: 2
      }
      expect(response).to have_http_status(:ok)

      expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date)).to eq(
        (days + [[2026, 5, 2]]).map { |day| [Time.zone.local(*day), Time.zone.local(*day)] }
      )
    end

    # It ends when it starts, so the overlap check finds nothing to clash
    # with: a booking that evening, and a second notice, are both taken.
    it 'lets a reservation with no times share its day with an evening booking and another one with no times' do
      no_times = { start_hours: '', start_minutes: '', end_hours: '', end_minutes: '' }
      [no_times, { start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 0 }, no_times].each do |times|
        post '/api/v1/common-house-reservations', params: {
          token: token, resident_id: resident.id, start_year: 2026, start_month: 5, start_day: 1
        }.merge(times)

        expect(response).to have_http_status(:ok)
      end
      expect(CommonHouseReservation.count).to eq(3)
    end

    # Before, a blank time was read as midnight, so a blank start with a
    # real end booked the common house from midnight.
    it 'refuses a reservation with one time menu empty, and says to pick both' do
      [{ start_hours: '', start_minutes: '', end_hours: 17, end_minutes: 0 },
       { start_hours: 14, start_minutes: 0, end_hours: '', end_minutes: '' },
       { end_hours: 17, end_minutes: 0 },
       { start_hours: 14, start_minutes: 0 }].each do |times|
        post '/api/v1/common-house-reservations', params: {
          token: token, resident_id: resident.id, title: 'One time',
          start_year: 2026, start_month: 5, start_day: 1
        }.merge(times)

        expect(CommonHouseReservation.pluck(:start_date, :end_date)).to eq([])
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Pick both a start and an end time.')
      end
    end

    # The same edges as an event (events_controller_spec.rb says why these
    # minutes): PostgreSQL cannot store a time before midnight UTC on
    # November 24, 4714 BC or after the last microsecond of 294276. Before,
    # the overlap check read the database with the time and raised
    # PG::DatetimeFieldOverflow, a 500.
    it 'refuses a time the database cannot store, one minute past each end, and takes the minute inside' do
      outside_and_inside = [
        [{ start_year: 294_276, start_month: 12, start_day: 31, start_hours: 15, start_minutes: 0 },
         { end_hours: 16, end_minutes: 0 }, { end_hours: 15, end_minutes: 59 }],
        [{ start_year: -4713, start_month: 11, start_day: 23, end_hours: 17, end_minutes: 0 },
         { start_hours: 16, start_minutes: 7 }, { start_hours: 16, start_minutes: 8 }]
      ]
      outside_and_inside.each do |day, outside, inside|
        [[outside, :bad_request], [inside, :ok]].each do |times, status|
          post '/api/v1/common-house-reservations',
               params: { token: token, resident_id: resident.id }.merge(day, times)

          expect(response).to have_http_status(status)
        end
        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been created')
      end

      post '/api/v1/common-house-reservations', params: {
        token: token, resident_id: resident.id, start_year: 300_000, start_month: 1, start_day: 1,
        start_hours: 14, start_minutes: 0, end_hours: 17, end_minutes: 0
      }
      expect(response.parsed_body).to eq('message' => 'Error: Invalid date')

      expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date)).to eq(
        [[Time.utc(294_276, 12, 31, 23, 0), Time.utc(294_276, 12, 31, 23, 59)],
         [Time.utc(-4713, 11, 24, 0, 0, 58), Time.utc(-4713, 11, 24, 0, 52, 58)]]
      )
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
      expect(response.parsed_body).to eq('message' => 'Time period is already taken')
      expect(CommonHouseReservation.count).to eq(1)
    end

    it 'lists every problem, one per line, when there is more than one' do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 5, 1, 14, 0),
                                        end_date: Time.zone.local(2026, 5, 1, 17, 0))

      post '/api/v1/common-house-reservations', params: {
        token: token,
        resident_id: 0, title: 'Conflict',
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 15, start_minutes: 0,
        end_hours: 18, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => "Resident must exist\nTime period is already taken")
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

    it 'lists every problem, one per line, when there is more than one, and changes nothing' do
      taken = Time.zone.local(2026, 5, 2, 14, 0)
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: taken, end_date: taken + 2.hours)
      moving = create(:common_house_reservation, community: community, resident: resident,
                                                 start_date: taken + 5.hours, end_date: taken + 6.hours)

      patch "/api/v1/common-house-reservations/#{moving.id}/update", params: {
        token: token,
        resident_id: 0, title: 'Moved',
        start_year: 2026, start_month: 5, start_day: 2,
        start_hours: 15, start_minutes: 0,
        end_hours: 16, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("Resident must exist\nTime period is already taken")
      expect(moving.reload).to have_attributes(resident_id: resident.id, start_date: taken + 5.hours)
    end

    # The same parser as create (#102).
    it 'refuses February 30 and one empty time menu, and leaves the reservation as it was' do
      chr = create(:common_house_reservation, community: community, resident: resident)
      before = chr.reload.attributes

      [[{ start_day: 30, start_hours: 10, start_minutes: 0, end_hours: 12, end_minutes: 0 }, 'Error: Invalid date'],
       [{ start_day: 1, start_hours: 10, start_minutes: 0, end_hours: '', end_minutes: '' },
        'Pick both a start and an end time.']].each do |changed, message|
        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
          token: token, resident_id: resident.id, title: 'Moved', start_year: 2026, start_month: 2
        }.merge(changed)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => message)
        expect(chr.reload.attributes).to eq(before)
      end
    end

    it 'moves a reservation to midnight to midnight when both time menus are emptied' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
        token: token, resident_id: resident.id, title: 'Cancelled', start_year: 2026, start_month: 3, start_day: 8,
        start_hours: '', start_minutes: '', end_hours: '', end_minutes: ''
      }

      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
      expect(chr.reload).to have_attributes(start_date: Time.zone.local(2026, 3, 8),
                                            end_date: Time.zone.local(2026, 3, 8), title: 'Cancelled')
    end

    it 'refuses a year the database cannot store, at either end, and leaves the reservation as it was' do
      chr = create(:common_house_reservation, community: community, resident: resident)
      before = chr.reload.attributes

      [300_000, -5000].each do |year|
        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
          token: token, resident_id: resident.id, title: 'Moved', start_year: year, start_month: 5, start_day: 1,
          start_hours: 10, start_minutes: 0, end_hours: 12, end_minutes: 0
        }

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

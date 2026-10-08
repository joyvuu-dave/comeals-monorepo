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

    # A booking that ends when it starts lasts zero minutes, so it would stop no
    # one from booking that afternoon (#141). Both menus empty, above, is
    # the one exception. The days are an ordinary one and both daylight
    # saving days.
    it 'refuses an end equal to its start, and takes an end one minute later' do
      days = [[2026, 5, 1], [2026, 3, 8], [2026, 11, 1]]
      days.each do |year, month, day|
        times = { token: token, resident_id: resident.id, title: 'Same time', start_year: year, start_month: month,
                  start_day: day, start_hours: 14, start_minutes: 0, end_hours: 14 }

        post '/api/v1/common-house-reservations', params: times.merge(end_minutes: 0)
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')

        post '/api/v1/common-house-reservations', params: times.merge(end_minutes: 1)
        expect(response).to have_http_status(:ok)
      end

      expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date)).to eq(
        days.map { |day| [Time.zone.local(*day, 14, 0), Time.zone.local(*day, 14, 1)] }
      )
    end

    # The time menus run from 08:00 to 22:00, but the edit form fills them
    # from the stored times, so saving a notice again sends 00:00 to 00:00
    # (the update example below). So picked 00:00 to 00:00 must save the
    # same row as both menus empty.
    it 'takes 00:00 to 00:00 picked on purpose, the same as both menus empty' do
      post '/api/v1/common-house-reservations', params: {
        token: token, resident_id: resident.id, start_year: 2026, start_month: 3, start_day: 8,
        start_hours: 0, start_minutes: 0, end_hours: 0, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      expect(CommonHouseReservation.pluck(:start_date, :end_date)).to eq([[Time.zone.local(2026, 3, 8)] * 2])
    end

    # The API's start and end are on one day, but a booking made in admin
    # can run past midnight, and a reservation with no times at that
    # midnight overlaps it.
    it 'refuses a reservation with no times at a midnight that a booking made in admin runs past' do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 5, 1, 22, 0),
                                        end_date: Time.zone.local(2026, 5, 2, 2, 0))

      post '/api/v1/common-house-reservations', params: {
        token: token, resident_id: resident.id, start_year: 2026, start_month: 5, start_day: 2
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Time period is already taken')
      expect(CommonHouseReservation.count).to eq(1)
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

    # The same rule as an event (events_controller_spec.rb says it in
    # full): RFC 5545, section 3.3.5 (#125). 02:30 on 2026-03-08 does not
    # happen in Los Angeles and is read as 03:30 PDT; 01:30 on 2026-11-01
    # happens twice and is the first one, in PDT. The expected times are
    # in UTC.
    describe 'a time on a daylight saving night (#125)' do
      let(:spring_forward) { { start_year: 2026, start_month: 3, start_day: 8 } }
      let(:fall_back) { { start_year: 2026, start_month: 11, start_day: 1 } }

      def post_reservation(**parts)
        post '/api/v1/common-house-reservations', params: { token: token, resident_id: resident.id }.merge(parts)
      end

      it 'saves a start or an end in the spring-forward gap an hour later, at 03:30 PDT' do
        post_reservation(**spring_forward, start_hours: 2, start_minutes: 30, end_hours: 4, end_minutes: 0)
        expect(response).to have_http_status(:ok)
        post_reservation(**spring_forward, start_hours: 0, start_minutes: 0, end_hours: 2, end_minutes: 30)
        expect(response).to have_http_status(:ok)

        # 03:30 PDT is 10:30 UTC, 04:00 PDT is 11:00 UTC, midnight PST is 08:00 UTC.
        expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 11, 0)],
           [Time.utc(2026, 3, 8, 8, 0), Time.utc(2026, 3, 8, 10, 30)]]
        )
      end

      it 'saves a start or an end that happens twice on the fall-back night as the first one, in PDT' do
        post_reservation(**fall_back, start_hours: 1, start_minutes: 30, end_hours: 1, end_minutes: 45)
        expect(response).to have_http_status(:ok)
        post_reservation(**fall_back, start_hours: 0, start_minutes: 30, end_hours: 1, end_minutes: 30)
        expect(response).to have_http_status(:ok)

        # 01:30 PDT is 08:30 UTC. The second 01:30, in PST, would be 09:30 UTC.
        expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.utc(2026, 11, 1, 8, 30), Time.utc(2026, 11, 1, 8, 45)],
           [Time.utc(2026, 11, 1, 7, 30), Time.utc(2026, 11, 1, 8, 30)]]
        )
      end

      # A start in the gap moves an hour later, and an end after the gap
      # does not move. 02:30 to 03:00 becomes 03:30 to 03:00, and the model
      # refuses an end before its start. 02:30 to 03:30 becomes 03:30 to
      # 03:30, which ends when it starts, and the model refuses that too
      # (#141). 02:30 to 03:31 is one minute long.
      it 'refuses a start in the gap that moves past its end or onto it, and takes one that stays before it' do
        [[3, 0], [3, 30]].each do |end_hours, end_minutes|
          post_reservation(**spring_forward, start_hours: 2, start_minutes: 30, end_hours:, end_minutes:)
          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
        end
        expect(CommonHouseReservation.count).to eq(0)

        post_reservation(**spring_forward, start_hours: 2, start_minutes: 30, end_hours: 3, end_minutes: 31)
        expect(response).to have_http_status(:ok)
        expect(CommonHouseReservation.pluck(:start_date, :end_date))
          .to eq([[Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 10, 31)]])
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

    # On an ordinary day and on both daylight saving days.
    it 'moves a reservation to midnight to midnight when both time menus are emptied' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      [[2026, 5, 1], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
          token: token, resident_id: resident.id, title: 'Cancelled', start_year: year, start_month: month,
          start_day: day, start_hours: '', start_minutes: '', end_hours: '', end_minutes: ''
        }

        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
        expect(chr.reload).to have_attributes(start_date: Time.zone.local(year, month, day),
                                              end_date: Time.zone.local(year, month, day), title: 'Cancelled')
      end
    end

    # The edit form fills its time menus from the stored times, and for a
    # notice those are 00:00 and 00:00. The menus show empty, because 00:00
    # is not on the list, but Update still sends "00" for each part, as
    # JSON. So the API must take 00:00 to 00:00 picked, or no one could
    # save a notice again (#141). On an ordinary day and both daylight
    # saving days.
    it 'saves a notice again the way the edit form sends it, as 00:00 to 00:00, and keeps the same row' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      [[2026, 5, 1], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        midnight = Time.zone.local(year, month, day)
        chr.update!(title: 'No movie', start_date: midnight, end_date: midnight)
        before = chr.reload.attributes

        patch "/api/v1/common-house-reservations/#{chr.id}/update",
              params: { token: token, resident_id: resident.id, start_year: year, start_month: month,
                        start_day: day, start_hours: '00', start_minutes: '00', end_hours: '00',
                        end_minutes: '00', title: 'No movie' }.to_json,
              headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
        expect(chr.reload.attributes).to eq(before)
      end
    end

    # The same rule as create (#141), on an ordinary day and both daylight
    # saving days.
    it 'refuses an end equal to its start and leaves the reservation as it was, and takes an end one minute later' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      [[2026, 5, 1], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        before = chr.reload.attributes
        times = { token: token, resident_id: resident.id, title: 'Moved', start_year: year, start_month: month,
                  start_day: day, start_hours: 14, start_minutes: 0, end_hours: 14 }

        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: times.merge(end_minutes: 0)
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
        expect(chr.reload.attributes).to eq(before)

        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: times.merge(end_minutes: 1)
        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
        expect(chr.reload).to have_attributes(start_date: Time.zone.local(year, month, day, 14, 0),
                                              end_date: Time.zone.local(year, month, day, 14, 1))
      end
    end

    # Production has one booking from before #141 that ends when it starts,
    # not at midnight (1117). The edit form sends the stored times back, so
    # a new title must still save. A move to other times that end when
    # they start is refused, and a later end saves. The times here are
    # those of booking 1117: 17:30 to 17:30 on 2023-12-11.
    it 'saves a new title on a booking from before #141 that ends when it starts, not at midnight' do
      moment = Time.zone.local(2023, 12, 11, 17, 30)
      chr = create(:common_house_reservation, community: community, resident: resident, title: 'Finance Committee')
      chr.update_columns(start_date: moment, end_date: moment)
      form = { token: token, resident_id: resident.id, start_year: 2023, start_month: 12, start_day: 11,
               start_hours: '17', start_minutes: '30', end_hours: '17', end_minutes: '30' }

      patch "/api/v1/common-house-reservations/#{chr.id}/update",
            params: form.merge(title: 'Finance Committee [Zoom]').to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
      expect(chr.reload).to have_attributes(title: 'Finance Committee [Zoom]', start_date: moment, end_date: moment)

      patch "/api/v1/common-house-reservations/#{chr.id}/update",
            params: form.merge(start_hours: '14', end_hours: '14').to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
      expect(chr.reload).to have_attributes(start_date: moment, end_date: moment)

      patch "/api/v1/common-house-reservations/#{chr.id}/update", params: form.merge(end_hours: '18').to_json,
                                                                  headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
      expect(chr.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)
    end

    # The same rule as create (#125): 02:30 on 2026-03-08 is 03:30 PDT,
    # and 01:30 on 2026-11-01 is the first 01:30, in PDT.
    it 'moves a reservation into the spring-forward gap an hour later, and onto the first 01:30 of the fall-back ' \
       'night' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      [[{ start_month: 3, start_day: 8, start_hours: 2, start_minutes: 30, end_hours: 4, end_minutes: 0 },
        [Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 11, 0)]],
       [{ start_month: 11, start_day: 1, start_hours: 1, start_minutes: 30, end_hours: 1, end_minutes: 45 },
        [Time.utc(2026, 11, 1, 8, 30), Time.utc(2026, 11, 1, 8, 45)]]].each do |parts, saved|
        patch "/api/v1/common-house-reservations/#{chr.id}/update",
              params: { token: token, resident_id: resident.id, start_year: 2026 }.merge(parts)

        expect(response.parsed_body).to eq('message' => 'Common House Reservation has been updated')
        expect(chr.reload.attributes.values_at('start_date', 'end_date')).to eq(saved)
      end
    end

    # 02:30 to 03:30 becomes 03:30 to 03:30, which ends when it starts (#141).
    it 'refuses a start in the spring-forward gap that moves past its end or onto it, and leaves the reservation ' \
       'as it was' do
      chr = create(:common_house_reservation, community: community, resident: resident)
      before = chr.reload.attributes

      [[3, 0], [3, 30]].each do |end_hours, end_minutes|
        patch "/api/v1/common-house-reservations/#{chr.id}/update", params: {
          token: token, resident_id: resident.id, start_year: 2026, start_month: 3, start_day: 8,
          start_hours: 2, start_minutes: 30, end_hours:, end_minutes:
        }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
        expect(chr.reload.attributes).to eq(before)
      end
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

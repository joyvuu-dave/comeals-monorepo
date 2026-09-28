# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Events API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/events/:id' do
    # Before #103 show rendered the record itself, not a serializer, so
    # every column went out, community_id included. The keys are the ones
    # public/api.md lists; the edit form reads all but the timestamps.
    it 'returns the event\'s fields that public/api.md lists, value by value, and no other column' do
      event = create(:event, community: community, title: 'Work party', description: 'Bring gloves', allday: false,
                             start_date: Time.zone.local(2026, 9, 5, 9, 0),
                             end_date: Time.zone.local(2026, 9, 5, 12, 30))

      get "/api/v1/events/#{event.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'id' => event.id, 'title' => 'Work party', 'description' => 'Bring gloves', 'allday' => false,
        'start_date' => '2026-09-05T09:00:00.000-07:00', 'end_date' => '2026-09-05T12:30:00.000-07:00',
        'created_at' => event.created_at.as_json, 'updated_at' => event.updated_at.as_json
      )
    end

    it 'returns an all-day event with no end' do
      event = create(:event, community: community, allday: true, start_date: Time.zone.local(2026, 9, 5, 0, 0),
                             end_date: nil)

      get "/api/v1/events/#{event.id}", params: { token: token }

      expect(response.parsed_body).to include('allday' => true, 'start_date' => '2026-09-05T00:00:00.000-07:00',
                                              'end_date' => nil)
    end

    it 'returns 404 for nonexistent event' do
      get '/api/v1/events/999999', params: { token: token }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/events' do
    it 'creates a timed event' do
      post '/api/v1/events', params: {
        token: token,
        title: 'Movie Night', description: 'Bring popcorn',
        all_day: false,
        start_year: 2026, start_month: 4, start_day: 15,
        start_hours: 19, start_minutes: 0,
        end_hours: 21, end_minutes: 30
      }

      expect(response).to have_http_status(:ok)
      event = Event.last
      expect(event).to have_attributes(title: 'Movie Night', description: 'Bring popcorn', allday: false,
                                       start_date: Time.zone.local(2026, 4, 15, 19, 0),
                                       end_date: Time.zone.local(2026, 4, 15, 21, 30))
    end

    it 'creates a timed event when all_day is left out' do
      post '/api/v1/events', params: {
        token: token,
        title: 'Quiet Hour', description: '',
        start_year: 2026, start_month: 4, start_day: 16,
        start_hours: 8, start_minutes: 0,
        end_hours: 9, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      expect(Event.last.allday).to be(false)
    end

    it 'returns 400 for a month that does not exist' do
      post '/api/v1/events', params: {
        token: token,
        title: 'Never', all_day: true,
        start_year: 2026, start_month: 13, start_day: 1
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
      expect(Event.count).to eq(0)
    end

    # Before #102 the parser rolled February 30 over to March 2 and saved
    # the event there.
    it 'returns 400 for a day that does not exist in its month' do
      post '/api/v1/events', params: {
        token: token,
        title: 'Never', all_day: false,
        start_year: 2026, start_month: 2, start_day: 30,
        start_hours: 19, start_minutes: 0,
        end_hours: 21, end_minutes: 0
      }

      expect(Event.pluck(:start_date, :end_date)).to eq([])
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
    end

    # Before #102 a blank hour was read as 0, so a timed event with no
    # times was saved from midnight to midnight.
    it 'refuses a timed event with no times, the way the form sends it when both time menus are empty' do
      post '/api/v1/events', params: {
        token: token,
        title: 'No times', all_day: false,
        start_year: 2026, start_month: 4, start_day: 15,
        start_hours: '', start_minutes: '',
        end_hours: '', end_minutes: ''
      }

      expect(Event.pluck(:start_date, :end_date)).to eq([])
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
    end

    describe 'the date and time parts (#102)' do
      let(:parts) do
        { start_year: 2026, start_month: 4, start_day: 15,
          start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 30 }
      end

      def post_event(**changed)
        post '/api/v1/events', params: { token: token, title: 'Parts', all_day: false }.merge(parts, changed)
      end

      def expect_refused
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Error: Invalid date')
        expect(Event.count).to eq(0)
      end

      it 'refuses a blank start time with a real end time' do
        post_event(start_hours: '', start_minutes: '')

        expect_refused
      end

      it 'refuses each time part left out, blank, or not a whole number' do
        %i[start_hours start_minutes end_hours end_minutes].product([nil, '', '7pm', '19.5']).each do |key, value|
          post_event(key => value)

          expect_refused
        end
      end

      it 'refuses a day, month or year left out, blank, or not a whole number' do
        %i[start_year start_month start_day].product([nil, '', 'May', '1.5']).each do |key, value|
          post_event(key => value)

          expect_refused
        end
      end

      # Hour 24 used to roll over to midnight the next day, and a negative
      # month or day would count back from the end of the year or month.
      it 'refuses an hour, minute, month or day out of range' do
        [{ start_hours: 24 }, { end_hours: 24 }, { start_hours: -1 }, { end_hours: -1 },
         { start_minutes: 60 }, { end_minutes: 60 }, { start_minutes: -1 }, { end_minutes: -1 },
         { start_month: 0 }, { start_month: -1 }, { start_day: 0 }, { start_day: -1 },
         { start_month: 4, start_day: 31 }].each do |changed|
          post_event(**changed)

          expect_refused
        end
      end

      it 'takes the first and last hour and minute of the day, at the start and at the end' do
        [[0, 0, 23, 59], [0, 0, 0, 30], [0, 59, 1, 0], [23, 0, 23, 30]].each do |start_hours, start_minutes, end_hours,
                                                                                  end_minutes|
          post_event(start_hours: start_hours, start_minutes: start_minutes, end_hours: end_hours,
                     end_minutes: end_minutes)
          expect(response).to have_http_status(:ok)
        end

        expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.zone.local(2026, 4, 15, 0, 0), Time.zone.local(2026, 4, 15, 23, 59)],
           [Time.zone.local(2026, 4, 15, 0, 0), Time.zone.local(2026, 4, 15, 0, 30)],
           [Time.zone.local(2026, 4, 15, 0, 59), Time.zone.local(2026, 4, 15, 1, 0)],
           [Time.zone.local(2026, 4, 15, 23, 0), Time.zone.local(2026, 4, 15, 23, 30)]]
        )
      end

      it 'takes February 29 in a leap year and refuses it in any other, and takes the first and last day of a month' do
        [[2028, 2, 29], [2026, 4, 30], [2026, 12, 31], [2027, 1, 1]].each do |year, month, day|
          post_event(start_year: year, start_month: month, start_day: day)
          expect(response).to have_http_status(:ok)
        end
        expect(Event.order(:id).pluck(:start_date)).to eq(
          [Time.zone.local(2028, 2, 29, 19, 0), Time.zone.local(2026, 4, 30, 19, 0),
           Time.zone.local(2026, 12, 31, 19, 0), Time.zone.local(2027, 1, 1, 19, 0)]
        )

        post_event(start_month: 2, start_day: 29)
        expect(response).to have_http_status(:bad_request)
        expect(Event.count).to eq(4)
      end

      # Days are counted in the Gregorian calendar carried back before
      # 1582, which Ruby's Time and PostgreSQL both use. Ruby's Date
      # counts days before October 15, 1582 in the Julian calendar, where
      # every fourth year is a leap year. So the parser took February 29,
      # 1500, and Time.zone.local saved it as March 1. It also refused
      # October 5 to 14, 1582, the ten days the change of calendar left
      # out of the Julian count.
      it 'counts days in the Gregorian calendar before 1582 too' do
        post_event(start_year: 1500, start_month: 2, start_day: 29)
        expect_refused

        [[1582, 10, 10], [1600, 2, 29]].each do |year, month, day|
          post_event(start_year: year, start_month: month, start_day: day)
          expect(response).to have_http_status(:ok)
        end
        expect(Event.order(:id).pluck(:start_date))
          .to eq([Time.zone.local(1582, 10, 10, 19, 0), Time.zone.local(1600, 2, 29, 19, 0)])
      end

      # PostgreSQL stores a timestamp from midnight UTC on November 24,
      # 4714 BC (Ruby's year -4713, because Ruby counts 1 BC as year 0)
      # up to the last microsecond of 294276. A time outside that raised
      # PG::DatetimeFieldOverflow on save, a 500. The community is in Los
      # Angeles, so both ends fall inside a local day: 16:00 on December
      # 31, 294276 is already 294277 in UTC, and before 1883 Los Angeles
      # kept local mean time, 7:52:58 behind UTC, so 16:07 on November 23,
      # 4714 BC is still before the first instant and 16:08 is after it.
      def last_storable_day
        { start_year: 294_276, start_month: 12, start_day: 31 }
      end

      def first_storable_day
        { start_year: -4713, start_month: 11, start_day: 23 }
      end

      it 'refuses an end one minute past the last instant, and a start one minute before the first' do
        post_event(**last_storable_day, start_hours: 15, start_minutes: 0, end_hours: 16, end_minutes: 0)
        expect_refused

        post_event(**first_storable_day, start_hours: 16, start_minutes: 7, end_hours: 17, end_minutes: 0)
        expect_refused
      end

      it 'takes the last minute before the last instant, and the first minute after the first' do
        post_event(**last_storable_day, start_hours: 15, start_minutes: 0, end_hours: 15, end_minutes: 59)
        expect(response).to have_http_status(:ok)
        post_event(**first_storable_day, start_hours: 16, start_minutes: 8, end_hours: 17, end_minutes: 0)
        expect(response).to have_http_status(:ok)

        expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.utc(294_276, 12, 31, 23, 0), Time.utc(294_276, 12, 31, 23, 59)],
           [Time.utc(-4713, 11, 24, 0, 0, 58), Time.utc(-4713, 11, 24, 0, 52, 58)]]
        )
      end

      it 'refuses years far outside, and a year with more digits than any time has' do
        [300_000, -5000, 10**30, -(10**30)].each do |year|
          post_event(start_year: year)

          expect_refused
        end
      end

      # An all-day event starts at local midnight, so a day is refused
      # when its midnight is outside, even if part of it is inside.
      it 'refuses an all-day event on a day whose midnight is outside, and takes the day next to it' do
        { [294_276, 12, 31] => :ok, [294_277, 1, 1] => :bad_request,
          [-4713, 11, 24] => :ok, [-4713, 11, 23] => :bad_request }.each do |(year, month, day), status|
          post_event(all_day: true, start_year: year, start_month: month, start_day: day)

          expect(response).to have_http_status(status)
        end

        expect(Event.order(:id).pluck(:start_date))
          .to eq([Time.utc(294_276, 12, 31, 8, 0), Time.utc(-4713, 11, 24, 7, 52, 58)])
      end

      # The SPA sends a JSON body: the day parts as numbers, the hours and
      # minutes as strings, "08" with its zero. api.md shows them all as
      # numbers.
      it 'reads the parts the way the SPA sends them, and as JSON numbers' do
        [{ start_hours: '08', start_minutes: '05', end_hours: '09', end_minutes: '30' },
         { start_hours: 8, start_minutes: 5, end_hours: 9, end_minutes: 30 }].each do |times|
          post '/api/v1/events', params: { token: token, title: 'JSON', all_day: false }.merge(parts, times).to_json,
                                 headers: { 'CONTENT_TYPE' => 'application/json' }

          expect(response).to have_http_status(:ok)
        end

        expect(Event.pluck(:start_date, :end_date))
          .to eq([[Time.zone.local(2026, 4, 15, 8, 5), Time.zone.local(2026, 4, 15, 9, 30)]] * 2)
      end

      it 'ignores the time parts of an all-day event, even blank ones' do
        post_event(all_day: true, start_hours: '', start_minutes: '', end_hours: '', end_minutes: '')

        expect(response).to have_http_status(:ok)
        expect(Event.last).to have_attributes(allday: true, start_date: Time.zone.local(2026, 4, 15, 0, 0),
                                              end_date: nil)
      end
    end

    it 'creates an all-day event' do
      post '/api/v1/events', params: {
        token: token,
        title: 'Work Day', all_day: true,
        start_year: 2026, start_month: 4, start_day: 20
      }

      expect(response).to have_http_status(:ok)
      event = Event.last
      expect(event.allday).to be(true)
      expect(event.end_date).to be_nil
    end

    it 'returns 400 without a title, and says so' do
      post '/api/v1/events', params: {
        token: token,
        title: '', all_day: true,
        start_year: 2026, start_month: 5, start_day: 1
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => "Title can't be blank")
    end

    it 'lists every problem, one per line, when there is more than one' do
      post '/api/v1/events', params: {
        token: token, title: '', all_day: false,
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 20, start_minutes: 0,
        end_hours: 18, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => "Title can't be blank\nStart time must occur before end time")
    end
  end

  describe 'PATCH /api/v1/events/:id/update' do
    let!(:event) { create(:event, community: community) }

    it 'updates the event' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, title: 'Updated Title', description: 'New desc',
        all_day: false,
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 18, start_minutes: 0,
        end_hours: 20, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      event.reload
      expect(event).to have_attributes(title: 'Updated Title', description: 'New desc', allday: false)
      expect([event.start_date, event.end_date]).to eq([Time.zone.local(2026, 5, 1, 18, 0),
                                                        Time.zone.local(2026, 5, 1, 20, 0)])
    end

    it 'turns a timed event into an all-day one when all_day is true, with no end' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, title: 'Work Day', all_day: true,
        start_year: 2026, start_month: 5, start_day: 1
      }

      expect(response).to have_http_status(:ok)
      event.reload
      expect(event).to have_attributes(allday: true, start_date: Time.zone.local(2026, 5, 1, 0, 0), end_date: nil)
    end

    it 'turns an all-day event into a timed one when all_day is false' do
      event.update!(allday: true, start_date: Time.zone.local(2026, 5, 1, 0, 0), end_date: nil)

      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, all_day: false,
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 18, start_minutes: 0,
        end_hours: 20, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      event.reload
      expect(event).to have_attributes(allday: false, start_date: Time.zone.local(2026, 5, 1, 18, 0),
                                       end_date: Time.zone.local(2026, 5, 1, 20, 0))
    end

    it 'lists every problem, one per line, when there is more than one' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, title: '', all_day: false,
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 20, start_minutes: 0,
        end_hours: 18, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("Title can't be blank\nStart time must occur before end time")
    end

    # A field left out of the body keeps its stored value. description is
    # NOT NULL in the database with no model validation, so before #69 a
    # missing description reached the database as nil and returned a 500.
    it 'keeps the stored description and title when the body leaves them out' do
      event.update!(title: 'Work party', description: 'Bring gloves')

      patch "/api/v1/events/#{event.id}/update", params: {
        token: token,
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 18, start_minutes: 0,
        end_hours: 20, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      event.reload
      expect(event.title).to eq('Work party')
      expect(event.description).to eq('Bring gloves')
      expect(event.start_date.hour).to eq(18)
    end

    it 'still refuses an empty title sent on purpose' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, title: '',
        start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 18, start_minutes: 0,
        end_hours: 20, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include("Title can't be blank")
    end

    # The same parser as create (#102).
    it 'refuses February 30 and blank times, and leaves the event as it was' do
      before = event.reload.attributes
      [{ start_day: 30, start_hours: 18, start_minutes: 0, end_hours: 20, end_minutes: 0 },
       { start_day: 1, start_hours: '', start_minutes: '', end_hours: '', end_minutes: '' }].each do |changed|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, title: 'Moved', all_day: false, start_year: 2026, start_month: 2
        }.merge(changed)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Error: Invalid date')
        expect(event.reload.attributes).to eq(before)
      end
    end

    it 'refuses a year the database cannot store, at either end, and leaves the event as it was' do
      before = event.reload.attributes
      [{ all_day: true, start_year: 300_000 }, { all_day: false, start_year: -5000 }].each do |changed|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, title: 'Moved', start_month: 5, start_day: 1,
          start_hours: 18, start_minutes: 0, end_hours: 20, end_minutes: 0
        }.merge(changed)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Error: Invalid date')
        expect(event.reload.attributes).to eq(before)
      end
    end

    it 'returns 400 for invalid date params' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, title: 'Updated Title',
        all_day: false,
        start_year: 0, start_month: 0, start_day: 0,
        start_hours: 0, start_minutes: 0,
        end_hours: 0, end_minutes: 0
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error: Invalid date')
    end
  end

  describe 'DELETE /api/v1/events/:id/delete' do
    let!(:event) { create(:event, community: community) }

    it 'deletes the event' do
      expect do
        delete "/api/v1/events/#{event.id}/delete", params: { token: token }
      end.to change(Event, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end
end

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

    # Issue #138. all_day follows the rule of every true/false value the
    # API reads. Before, only the text "true" was true: "1" made a timed
    # event, and so did every other value, "True" and "yes" included.
    describe 'all_day' do
      let(:day) { { start_year: 2026, start_month: 4, start_day: 20 } }
      let(:times) { { start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 0 } }

      it 'refuses all_day "True", "yes", "" or a list, and saves nothing' do
        ['True', 'yes', '', ['true']].each do |all_day|
          post '/api/v1/events', params: { token: token, title: 'Work Day', all_day: all_day }.merge(day, times)

          expect(response).to have_http_status(:bad_request), all_day.inspect
          expect(response.parsed_body).to eq('message' => 'All day must be true or false')
        end
        expect(Event.count).to eq(0)
      end

      it 'refuses all_day sent as JSON null, and saves nothing' do
        post '/api/v1/events', params: { token: token, title: 'Work Day', all_day: nil }.merge(day, times).to_json,
                               headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'All day must be true or false')
        expect(Event.count).to eq(0)
      end

      it 'takes all_day 1 and 0, as JSON numbers and as text' do
        [1, '1', 0, '0'].each do |all_day|
          body = { token: token, title: 'Work Day', all_day: all_day }.merge(day, times)
          post '/api/v1/events', params: body.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }

          expect(response).to have_http_status(:ok), all_day.inspect
        end
        expect(Event.order(:id).pluck(:allday, :end_date))
          .to eq([[true, nil], [true, nil],
                  [false, Time.zone.local(2026, 4, 20, 21, 0)], [false, Time.zone.local(2026, 4, 20, 21, 0)]])
      end
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

    # The form sends '' for each part of an empty time menu; a direct API
    # call may leave the parts out. Midnight exists on both daylight saving
    # days in the community's zone, so those days get midnight too.
    it 'saves a timed event with both time menus empty from midnight to midnight' do
      days = [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]]
      days.each do |year, month, day|
        post '/api/v1/events', params: {
          token: token, title: 'No times', all_day: false,
          start_year: year, start_month: month, start_day: day,
          start_hours: '', start_minutes: '', end_hours: '', end_minutes: ''
        }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('message' => 'Event has been created')
      end
      post '/api/v1/events',
           params: { token: token, title: 'No times', start_year: 2026, start_month: 4, start_day: 16 }
      expect(response).to have_http_status(:ok)

      expect(Event.order(:id).pluck(:start_date, :end_date, :allday)).to eq(
        (days + [[2026, 4, 16]]).map { |day| [Time.zone.local(*day), Time.zone.local(*day), false] }
      )
    end

    # An event that ends when it starts lasts zero minutes (#141). Both menus
    # empty, above, is the one exception. The days are an ordinary one and
    # both daylight saving days.
    it 'refuses an end equal to its start, and takes an end one minute later' do
      days = [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]]
      days.each do |year, month, day|
        times = { token: token, title: 'Same time', all_day: false, start_year: year, start_month: month,
                  start_day: day, start_hours: 14, start_minutes: 0, end_hours: 14 }

        post '/api/v1/events', params: times.merge(end_minutes: 0)
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')

        post '/api/v1/events', params: times.merge(end_minutes: 1)
        expect(response).to have_http_status(:ok)
      end

      expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(
        days.map { |day| [Time.zone.local(*day, 14, 0), Time.zone.local(*day, 14, 1)] }
      )
    end

    # The time menus run from 08:00 to 22:00, but the edit form fills them
    # from the stored times, so saving a notice again sends 00:00 to 00:00
    # (the update example below). So picked 00:00 to 00:00 must save the
    # same row as both menus empty.
    it 'takes 00:00 to 00:00 picked on purpose, the same as both menus empty' do
      post '/api/v1/events', params: {
        token: token, title: 'Picked midnight', all_day: false, start_year: 2026, start_month: 3, start_day: 8,
        start_hours: 0, start_minutes: 0, end_hours: 0, end_minutes: 0
      }

      expect(response).to have_http_status(:ok)
      expect(Event.pluck(:start_date, :end_date)).to eq([[Time.zone.local(2026, 3, 8)] * 2])
    end

    describe 'the date and time parts (#102)' do
      let(:parts) do
        { start_year: 2026, start_month: 4, start_day: 15,
          start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 30 }
      end

      def post_event(**changed)
        post '/api/v1/events', params: { token: token, title: 'Parts', all_day: false }.merge(parts, changed)
      end

      def post_event_without(key)
        post '/api/v1/events', params: { token: token, title: 'Parts', all_day: false }.merge(parts).except(key)
      end

      def expect_refused
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Error: Invalid date')
        expect(Event.count).to eq(0)
      end

      # Before, a blank time was read as midnight, so a blank start with a
      # real end was saved from midnight.
      it 'refuses one time menu empty, blank or left out, and says to pick both' do
        [%i[start_hours start_minutes], %i[end_hours end_minutes]].each do |hours, minutes|
          post_event(hours => '', minutes => '')
          expect(response.parsed_body).to eq('message' => 'Pick both a start and an end time.')

          post '/api/v1/events',
               params: { token: token, title: 'Parts', all_day: false }.merge(parts).except(hours, minutes)
          expect(response.parsed_body).to eq('message' => 'Pick both a start and an end time.')
        end

        expect(response).to have_http_status(:bad_request)
        expect(Event.count).to eq(0)
      end

      # A part sent with no value (nil) still has its key in the body; a
      # part left out has none, and must get the same 400, not a 500.
      it 'refuses each time part left out, sent with no value, blank, or not a whole number' do
        bad_values = [nil, '', '7pm', '19.5']
        %i[start_hours start_minutes end_hours end_minutes].each do |key|
          post_event_without(key)
          expect_refused

          bad_values.each do |value|
            post_event(key => value)
            expect_refused
          end
        end
      end

      it 'refuses a day, month or year left out, sent with no value, blank, or not a whole number' do
        bad_values = [nil, '', 'May', '1.5']
        %i[start_year start_month start_day].each do |key|
          post_event_without(key)
          expect_refused

          bad_values.each do |value|
            post_event(key => value)
            expect_refused
          end
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

      # The SPA's event forms send all_day as a JSON true or false, not
      # the text "true".
      it 'makes an all-day event from the JSON true the SPA sends' do
        post '/api/v1/events', params: { token: token, title: 'JSON', all_day: true }.merge(parts).to_json,
                               headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:ok)
        expect(Event.last).to have_attributes(allday: true, start_date: Time.zone.local(2026, 4, 15, 0, 0),
                                              end_date: nil)
      end

      it 'ignores the time parts of an all-day event, even blank ones' do
        post_event(all_day: true, start_hours: '', start_minutes: '', end_hours: '', end_minutes: '')

        expect(response).to have_http_status(:ok)
        expect(Event.last).to have_attributes(allday: true, start_date: Time.zone.local(2026, 4, 15, 0, 0),
                                              end_date: nil)
      end
    end

    # A local time the clock skips or shows twice is read by the rule in
    # RFC 5545, section 3.3.5 (#125). The community is in Los Angeles. On
    # 2026-03-08 the clock goes from 01:59 PST to 03:00 PDT, so 02:30 does
    # not happen. It is read with the offset from before the gap, UTC-8,
    # and 02:30 PST is 03:30 PDT. On 2026-11-01 the clock goes from 01:59
    # PDT back to 01:00 PST, so 01:30 happens twice, and the first one,
    # PDT (UTC-7), is saved. The expected times are in UTC, so they do not
    # depend on the zone the spec runs in.
    describe 'a time on a daylight saving night (#125)' do
      let(:spring_forward) { { start_year: 2026, start_month: 3, start_day: 8 } }
      let(:fall_back) { { start_year: 2026, start_month: 11, start_day: 1 } }

      def post_event(**parts)
        post '/api/v1/events', params: { token: token, title: 'Night', all_day: false }.merge(parts)
      end

      it 'saves a start or an end in the spring-forward gap an hour later, at 03:30 PDT' do
        post_event(**spring_forward, start_hours: 2, start_minutes: 30, end_hours: 4, end_minutes: 0)
        expect(response).to have_http_status(:ok)
        post_event(**spring_forward, start_hours: 1, start_minutes: 0, end_hours: 2, end_minutes: 30)
        expect(response).to have_http_status(:ok)

        # 03:30 PDT is 10:30 UTC, 04:00 PDT is 11:00 UTC, 01:00 PST is 09:00 UTC.
        expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 11, 0)],
           [Time.utc(2026, 3, 8, 9, 0), Time.utc(2026, 3, 8, 10, 30)]]
        )
      end

      it 'saves a start or an end that happens twice on the fall-back night as the first one, in PDT' do
        post_event(**fall_back, start_hours: 1, start_minutes: 30, end_hours: 1, end_minutes: 45)
        expect(response).to have_http_status(:ok)
        post_event(**fall_back, start_hours: 0, start_minutes: 30, end_hours: 1, end_minutes: 30)
        expect(response).to have_http_status(:ok)

        # 01:30 PDT is 08:30 UTC. The second 01:30, in PST, would be 09:30 UTC.
        expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(
          [[Time.utc(2026, 11, 1, 8, 30), Time.utc(2026, 11, 1, 8, 45)],
           [Time.utc(2026, 11, 1, 7, 30), Time.utc(2026, 11, 1, 8, 30)]]
        )
      end

      it 'starts an all-day event at midnight on both nights, because midnight happens once on each' do
        [spring_forward, fall_back].each do |day|
          post_event(**day, all_day: true)
          expect(response).to have_http_status(:ok)
        end

        # Midnight PST on 2026-03-08 is 08:00 UTC; midnight PDT on 2026-11-01 is 07:00 UTC.
        expect(Event.order(:id).pluck(:start_date, :end_date, :allday)).to eq(
          [[Time.utc(2026, 3, 8, 8, 0), nil, true], [Time.utc(2026, 11, 1, 7, 0), nil, true]]
        )
      end

      # A start in the gap moves an hour later, and an end after the gap
      # does not move, so the two can meet or cross. 02:30 to 03:00 becomes
      # 03:30 to 03:00, and the model refuses an end before its start.
      # 02:30 to 03:30 becomes 03:30 to 03:30, an event that ends when it
      # starts, and the model refuses that too (#141). 02:30 to 03:31 is
      # one minute long.
      it 'refuses a start in the gap that moves past its end or onto it, and takes one that stays before it' do
        [[3, 0], [3, 30]].each do |end_hours, end_minutes|
          post_event(**spring_forward, start_hours: 2, start_minutes: 30, end_hours:, end_minutes:)
          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
        end
        expect(Event.count).to eq(0)

        post_event(**spring_forward, start_hours: 2, start_minutes: 30, end_hours: 3, end_minutes: 31)
        expect(response).to have_http_status(:ok)
        expect(Event.pluck(:start_date, :end_date))
          .to eq([[Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 10, 31)]])
      end

      # The examples above check Los Angeles in 2026, through the API. The
      # API reads a time with Time.zone.local, and its rule is not written
      # the way the RFC writes it (ApiController#parse_start_end_params
      # says how). The next two examples check where the two rules give
      # the same answer, and pin one place where they do not. Inside a
      # clock change, the RFC reads a skipped time with the UTC offset from
      # before the change. Of a time shown twice it takes the first, which
      # is also the one with the offset from before the change. This
      # checks each change at the first, middle and last whole minute that
      # the clock skips or shows twice.
      def reads_at_clock_changes(zone_name, from, to)
        zone = ActiveSupport::TimeZone[zone_name]
        TZInfo::Timezone.get(zone_name).transitions_up_to(to, from).flat_map do |change|
          offset_before = change.previous_offset.observed_utc_offset
          edges = [offset_before, change.offset.observed_utc_offset].map { |offset| change.timestamp_value + offset }
          first, past_last = edges.sort
          [first.ceildiv(60), (first + past_last) / 120, (past_last - 1) / 60].uniq.map do |minute|
            wall = Time.at(minute * 60).utc
            { wall: "#{zone_name} #{wall.strftime('%F %R')}",
              read: zone.local(wall.year, wall.month, wall.day, wall.hour, wall.min).utc,
              rfc: Time.at((minute * 60) - offset_before).utc }
          end
        end
      end

      it 'reads a time the RFC way at every clock change from 1972 to 2100, in every zone a community can use' do
        reads = Community::SUPPORTED_TIMEZONES.values.flat_map do |zone_name|
          reads_at_clock_changes(zone_name, Time.utc(1972), Time.utc(2101))
        end

        expect(reads.pluck(:wall)).to include(
          'America/Los_Angeles 2026-03-08 02:30', 'America/Los_Angeles 2026-11-01 01:30'
        )
        expect(reads.reject { |read| read[:read] == read[:rfc] }).to eq([])
      end

      # At noon on 1883-11-18, Los Angeles moved its clocks from local sun
      # time (UTC-7:52:58) back to PST (UTC-8), so 12:00 to 12:07 happened
      # twice. The RFC says 12:05 is the first one, 19:57:58 UTC. This
      # pins the difference that ApiController#parse_start_end_params
      # writes down: if it starts to fail, that comment and public/api.md
      # are out of date.
      it 'saves a time shown twice in 1883 as the second one, which is not the RFC answer' do
        post_event(start_year: 1883, start_month: 11, start_day: 18,
                   start_hours: 12, start_minutes: 5, end_hours: 13, end_minutes: 0)

        expect(response).to have_http_status(:ok)
        expect(Event.last.start_date).to eq(Time.utc(1883, 11, 18, 20, 5))
        expect(reads_at_clock_changes('America/Los_Angeles', Time.utc(1883), Time.utc(1884))).to include(
          { wall: 'America/Los_Angeles 1883-11-18 12:03', read: Time.utc(1883, 11, 18, 20, 3),
            rfc: Time.utc(1883, 11, 18, 19, 55, 58) }
        )
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

    it 'turns a timed event into an all-day one from the JSON true the SPA sends' do
      patch "/api/v1/events/#{event.id}/update",
            params: { token: token, title: 'Work Day', all_day: true,
                      start_year: 2026, start_month: 5, start_day: 1 }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(allday: true, start_date: Time.zone.local(2026, 5, 1, 0, 0),
                                              end_date: nil)
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

    it 'keeps the stored all_day when the body leaves it out' do
      event.update!(allday: true, start_date: Time.zone.local(2026, 5, 1, 0, 0), end_date: nil)

      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, start_year: 2026, start_month: 5, start_day: 2
      }

      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(allday: true, start_date: Time.zone.local(2026, 5, 2, 0, 0),
                                              end_date: nil)
    end

    # Issue #138: before, "no" was read as false and the event became a
    # timed one, with a 200.
    it 'refuses all_day "no" or "", and leaves the event as it was' do
      event.update!(allday: true, start_date: Time.zone.local(2026, 5, 1, 0, 0), end_date: nil)
      before = event.reload.attributes

      ['no', ''].each do |all_day|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, title: 'Moved', all_day: all_day,
          start_year: 2026, start_month: 5, start_day: 2,
          start_hours: 18, start_minutes: 0, end_hours: 20, end_minutes: 0
        }

        expect(response).to have_http_status(:bad_request), all_day.inspect
        expect(response.parsed_body).to eq('message' => 'All day must be true or false')
      end
      expect(event.reload.attributes).to eq(before)
    end

    it 'takes all_day "1" as true and 0 as false' do
      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, all_day: '1', start_year: 2026, start_month: 5, start_day: 1
      }
      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(allday: true, end_date: nil)

      patch "/api/v1/events/#{event.id}/update", params: {
        token: token, all_day: 0, start_year: 2026, start_month: 5, start_day: 1,
        start_hours: 18, start_minutes: 0, end_hours: 20, end_minutes: 0
      }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(allday: false, end_date: Time.zone.local(2026, 5, 1, 20, 0))
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
    it 'refuses February 30 and one empty time menu, and leaves the event as it was' do
      before = event.reload.attributes
      [[{ start_day: 30, start_hours: 18, start_minutes: 0, end_hours: 20, end_minutes: 0 }, 'Error: Invalid date'],
       [{ start_day: 1, start_hours: '', start_minutes: '', end_hours: 20, end_minutes: 0 },
        'Pick both a start and an end time.']].each do |changed, message|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, title: 'Moved', all_day: false, start_year: 2026, start_month: 2
        }.merge(changed)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => message)
        expect(event.reload.attributes).to eq(before)
      end
    end

    # On an ordinary day and on both daylight saving days.
    it 'moves a timed event to midnight to midnight when both time menus are emptied' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, title: 'Moved', all_day: false, start_year: year, start_month: month, start_day: day,
          start_hours: '', start_minutes: '', end_hours: '', end_minutes: ''
        }

        expect(response.parsed_body).to eq('message' => 'Event has been updated')
        expect(event.reload).to have_attributes(start_date: Time.zone.local(year, month, day),
                                                end_date: Time.zone.local(year, month, day), allday: false)
      end
    end

    # The edit form fills its time menus from the stored times, and for a
    # notice those are 00:00 and 00:00. The menus show empty, because 00:00
    # is not on the list, but Update still sends "00" for each part, as
    # JSON. So the API must take 00:00 to 00:00 picked, or no one could
    # save a notice again (#141). On an ordinary day and both daylight
    # saving days.
    it 'saves a notice again the way the edit form sends it, as 00:00 to 00:00, and keeps the same row' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        midnight = Time.zone.local(year, month, day)
        event.update!(title: 'No movie', description: 'Cancelled', allday: false, start_date: midnight,
                      end_date: midnight)
        before = event.reload.attributes

        patch "/api/v1/events/#{event.id}/update",
              params: { token: token, title: 'No movie', description: 'Cancelled', start_year: year,
                        start_month: month, start_day: day, start_hours: '00', start_minutes: '00',
                        end_hours: '00', end_minutes: '00', all_day: false }.to_json,
              headers: { 'CONTENT_TYPE' => 'application/json' }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('message' => 'Event has been updated')
        expect(event.reload.attributes).to eq(before)
      end
    end

    # The same rule as create (#141), on an ordinary day and both daylight
    # saving days.
    it 'refuses an end equal to its start and leaves the event as it was, and takes an end one minute later' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |year, month, day|
        before = event.reload.attributes
        times = { start_year: year, start_month: month, start_day: day, start_hours: 14, start_minutes: 0,
                  end_hours: 14 }

        patch "/api/v1/events/#{event.id}/update",
              params: { token: token, title: 'Moved', all_day: false, end_minutes: 0 }.merge(times)
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
        expect(event.reload.attributes).to eq(before)

        patch "/api/v1/events/#{event.id}/update",
              params: { token: token, title: 'Moved', all_day: false, end_minutes: 1 }.merge(times)
        expect(response.parsed_body).to eq('message' => 'Event has been updated')
        expect(event.reload).to have_attributes(start_date: Time.zone.local(year, month, day, 14, 0),
                                                end_date: Time.zone.local(year, month, day, 14, 1))
      end
    end

    # Production has three events from before #141 that end when they
    # start, not at midnight (143, 489 and 1056). The edit form sends the
    # stored times back, so a new title must still save. A move to other
    # times that end when they start is refused, and a later end saves.
    # The times here are those of event 1056: 08:00 to 08:00 on 2022-07-26.
    it 'saves a new title on an event from before #141 that ends when it starts, not at midnight' do
      moment = Time.zone.local(2022, 7, 26, 8, 0)
      event.update_columns(title: 'WM Bulk Pick-up', allday: false, start_date: moment, end_date: moment)
      form = { token: token, description: '', all_day: false, start_year: 2022, start_month: 7, start_day: 26,
               start_hours: '08', start_minutes: '00', end_hours: '08', end_minutes: '00' }

      patch "/api/v1/events/#{event.id}/update", params: form.merge(title: 'WM Bulk Pick-up moved').to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => 'Event has been updated')
      expect(event.reload).to have_attributes(title: 'WM Bulk Pick-up moved', start_date: moment, end_date: moment)

      patch "/api/v1/events/#{event.id}/update",
            params: form.merge(start_hours: '14', end_hours: '14').to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
      expect(event.reload).to have_attributes(start_date: moment, end_date: moment)

      patch "/api/v1/events/#{event.id}/update", params: form.merge(end_hours: '09').to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response.parsed_body).to eq('message' => 'Event has been updated')
      expect(event.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)
    end

    # The same rule as create (#125): 02:30 on 2026-03-08 is 03:30 PDT,
    # and 01:30 on 2026-11-01 is the first 01:30, in PDT.
    it 'moves an event into the spring-forward gap an hour later, and onto the first 01:30 of the fall-back night' do
      [[{ start_month: 3, start_day: 8, start_hours: 2, start_minutes: 30, end_hours: 4, end_minutes: 0 },
        [Time.utc(2026, 3, 8, 10, 30), Time.utc(2026, 3, 8, 11, 0)]],
       [{ start_month: 11, start_day: 1, start_hours: 1, start_minutes: 30, end_hours: 1, end_minutes: 45 },
        [Time.utc(2026, 11, 1, 8, 30), Time.utc(2026, 11, 1, 8, 45)]]].each do |parts, saved|
        patch "/api/v1/events/#{event.id}/update", params: { token: token, all_day: false, start_year: 2026 }
          .merge(parts)

        expect(response.parsed_body).to eq('message' => 'Event has been updated')
        expect(event.reload.attributes.values_at('start_date', 'end_date')).to eq(saved)
      end
    end

    # 02:30 to 03:30 becomes 03:30 to 03:30, which ends when it starts (#141).
    it 'refuses a start in the spring-forward gap that moves past its end or onto it, and leaves the event as it was' do
      before = event.reload.attributes

      [[3, 0], [3, 30]].each do |end_hours, end_minutes|
        patch "/api/v1/events/#{event.id}/update", params: {
          token: token, all_day: false, start_year: 2026, start_month: 3, start_day: 8,
          start_hours: 2, start_minutes: 30, end_hours:, end_minutes:
        }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Start time must occur before end time')
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

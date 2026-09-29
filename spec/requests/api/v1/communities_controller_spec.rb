# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Communities API' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/communities/:id/hosts' do
    # The order by unit name is checked in write_messages_spec.rb.
    it 'returns active adults only, not children or retired residents' do
      adult = create(:resident, community: community, unit: unit, multiplier: 2, active: true)
      child = create(:resident, community: community, unit: unit, multiplier: 1, active: true)
      inactive = create(:resident, community: community, unit: unit, multiplier: 2, active: false,
                                   can_cook: false, email: nil)

      get "/api/v1/communities/#{community.id}/hosts", params: { token: token }

      expect(response).to have_http_status(:ok)
      host_ids = response.parsed_body.pluck(0)
      expect(host_ids).to contain_exactly(resident.id, adult.id)
      expect(host_ids).not_to include(child.id, inactive.id)
    end

    it 'returns 401 without a token' do
      get "/api/v1/communities/#{community.id}/hosts"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/communities/:id/birthdays' do
    def birthdays(params = {})
      get "/api/v1/communities/#{community.id}/birthdays", params: { token: token }.merge(params)
      response.parsed_body
    end

    # Two weeks after February 20 is March 6. One week after is still
    # February.
    it 'returns residents with birthdays in the month two weeks after start' do
      march_bday = create(:resident, community: community, unit: unit, name: 'Mae March',
                                     birthday: Date.new(1990, 3, 15))
      create(:resident, community: community, unit: unit, birthday: Date.new(1985, 2, 20))

      body = birthdays(start: '2026-02-20')

      expect(response).to have_http_status(:ok)
      expect(body.pluck('id', 'title', 'start'))
        .to eq([[march_bday.cache_key_with_version, "Mae's B-day!", '2026-03-15']])
    end

    # The clock is in December, so next month is also next year. A start
    # with no value (`?start`, no `=`) counts as no start, as api.md's
    # "Without start" reads; an empty `?start=` is not a date (below).
    it 'uses this month and this year when no start date is given, or a start with no value' do
      travel_to Time.zone.local(2026, 12, 20, 12, 0) do
        token
        born_now = create(:resident, community: community, unit: unit, name: 'Born Now',
                                     birthday: Date.new(1990, 12, 5))
        create(:resident, community: community, unit: unit, name: 'Born Later', birthday: Date.new(1990, 1, 5))

        body = birthdays

        expect(response).to have_http_status(:ok)
        expect(body.pluck('id', 'start')).to eq([[born_now.cache_key_with_version, '2026-12-05']])

        expect(birthdays(start: nil)).to eq(body)
        expect(response).to have_http_status(:ok)
      end
    end

    # The month two weeks after a start of December 27, 2026 is January
    # 2027. Viewed in September 2026, the chip is still dated 2027, and
    # the child's chip names the age turned that day (8), not today's (7).
    it 'dates the chips in the year of that month, not this year, with the age turned that day' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        token
        create(:resident, community: community, unit: unit, name: 'Ivy Jan', birthday: Date.new(2019, 1, 5))

        body = birthdays(start: '2026-12-27')

        expect(body.pluck('title', 'start')).to eq([["Ivy's 8th B-day!", '2027-01-05']])
      end
    end

    # A person has no birthday chip in a month before they were born.
    # Born on the last day of the month counts as born by then.
    it 'leaves out someone born after the month, and keeps someone born on its last day' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        token
        baby = create(:resident, community: community, unit: unit, name: 'Tia New', birthday: Date.new(2026, 3, 31))

        expect(birthdays(start: '2025-03-16')).to eq([])
        expect(birthdays(start: '2026-03-15').pluck('id', 'start'))
          .to eq([[baby.cache_key_with_version, '2026-03-31']])
      end
    end

    # Before this, Date.parse raised and the answer was a 500.
    it 'returns 400 for a start that is not a date, or not a string' do
      ['not-a-date', '', ['2026-03-01']].each do |start|
        birthdays(start: start)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => 'Invalid date')
      end
    end

    # An adult with no birthday must never appear — this is the fix for the
    # old 1900-01-01 placeholder, which put a dozen fake birthdays on Jan 1.
    it 'excludes residents with no birthday' do
      create(:resident, community: community, unit: unit, birthday: nil)

      get "/api/v1/communities/#{community.id}/birthdays", params: {
        token: token, start: '2026-01-01'
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_empty
    end
  end

  describe 'GET /api/v1/communities/:id/calendar/:date' do
    it 'returns calendar data for the month' do
      create(:meal, community: community, date: Date.new(2026, 4, 10))

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to have_key('month')
      expect(body).to have_key('year')
      expect(body['month']).to eq(4)
      expect(body['year']).to eq(2026)
    end

    # Birthdays in the calendar response must appear on the actual birthday
    # date: not shifted by a day, and in the year of the month on screen,
    # not this year (#101). The clock is in 2027 on purpose. This tests the
    # full pipeline: controller → serializer.
    it 'returns birthdays on the birthday, in the year of the month on screen' do
      travel_to Time.zone.local(2027, 2, 1, 12, 0) do
        token
        create(:resident, community: community, unit: unit, birthday: Date.new(1990, 4, 20))

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['birthdays'].pluck('start')).to eq(['2026-04-20'])
      end
    end

    # Regression: malformed date params must return 400, not crash with 500.
    it 'returns 400 for a malformed date parameter' do
      get "/api/v1/communities/#{community.id}/calendar/not-a-date", params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Invalid date')
    end

    # The clock is in September 2026, so neither month on screen is in
    # this year. The months are picked by number, and the January and
    # December grids each reach into the other year.
    it 'dates a January birthday in the January on screen (year boundary)' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        token
        create(:resident, community: community, unit: unit, birthday: Date.new(1990, 1, 15))

        get "/api/v1/communities/#{community.id}/calendar/2027-01-15", params: { token: token }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['birthdays'].pluck('start')).to eq(['2027-01-15'])
      end
    end

    it 'dates a December birthday in the December on screen (year boundary)' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        token
        create(:resident, community: community, unit: unit, birthday: Date.new(1990, 12, 20))

        get "/api/v1/communities/#{community.id}/calendar/2025-12-15", params: { token: token }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['birthdays'].pluck('start')).to eq(['2025-12-20'])
      end
    end

    it 'sets an ETag and returns 304 when If-None-Match matches' do
      create(:meal, community: community, date: Date.new(2026, 4, 10))

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

      expect(response).to have_http_status(:ok)
      etag = response.headers['ETag']
      expect(etag).to be_present
      expect(response.headers['Cache-Control']).to include('private')

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15",
          params: { token: token }, headers: { 'If-None-Match' => etag }

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
    end

    # The full pipeline for a change, against a real cache: the calendar
    # response is cached per month, so a change to a resident, a unit or a
    # meal only shows up because Community#calendar_cache_version is part
    # of the fetch (#77), and LiveUpdate deletes the month after a write.
    # The test env cache is a null store, so these swap in a MemoryStore —
    # without the version and the delete they would fail on stale data.
    describe 'a change, against a real cache' do
      around do |example|
        original_store = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rails.cache = original_store
      end

      let(:this_year) { Time.zone.today.year }

      it 'shows the birthday after an adult adds one' do
        resident = create(:resident, community: community, unit: unit, birthday: nil)

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).to be_empty

        resident.update!(birthday: Date.new(1980, 6, 5))

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).not_to be_empty
      end

      it 'removes the birthday after it is cleared' do
        resident = create(:resident, community: community, unit: unit,
                                     birthday: Date.new(1980, 6, 5))

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).not_to be_empty

        resident.update!(birthday: nil)

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).to be_empty
      end

      it 'shows the new name after a cook is renamed' do
        cook = create(:resident, community: community, unit: unit, name: 'Oldname')
        meal = create(:meal, community: community, date: Date.new(2026, 4, 10))
        create(:bill, meal: meal, resident: cook, amount: 10)

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
        expect(response.body).to include('Oldname')

        cook.update!(name: 'Newname')

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
        expect(response.body).not_to include('Oldname')
        expect(response.body).to include('Newname')
      end

      it 'drops the birthday after the resident is retired' do
        retiree = create(:resident, community: community, unit: unit, birthday: Date.new(1980, 6, 5))

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).not_to be_empty

        retiree.update!(active: false)

        get "/api/v1/communities/#{community.id}/calendar/#{this_year}-06-15", params: { token: token }
        expect(response.parsed_body['birthdays']).to be_empty
      end

      it 'shows the new unit name after a unit is renamed' do
        meal = create(:meal, community: community, date: Date.new(2026, 4, 10))
        create(:bill, meal: meal, resident: resident, amount: 10)
        unit.update!(name: 'Old Unit')

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
        expect(response.body).to include('Old Unit')

        unit.update!(name: 'New Unit')

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
        expect(response.body).not_to include('Old Unit')
        expect(response.body).to include('New Unit')
      end

      it 'returns a fresh 200 with a new ETag after a meal is added to the cached month' do
        create(:meal, community: community, date: Date.new(2026, 4, 10))

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
        first_etag = response.headers['ETag']
        expect(Rails.cache.exist?(community.calendar_cache_key(2026, 4))).to be(true)

        # A write through a model clears the month (LiveUpdate) and
        # changes its version.
        added = create(:meal, community: community, date: Date.new(2026, 4, 17))

        get "/api/v1/communities/#{community.id}/calendar/2026-04-15",
            params: { token: token }, headers: { 'If-None-Match' => first_etag }

        expect(response).to have_http_status(:ok)
        expect(response.headers['ETag']).not_to eq(first_etag)
        expect(response.parsed_body['meals'].pluck('url')).to include("/meals/#{added.id}/edit")
      end
    end
  end

  describe 'GET /api/v1/communities/:id/ical' do
    it 'returns an iCalendar feed (no auth required)' do
      create(:meal, community: community, date: Date.new(2026, 5, 1))

      get "/api/v1/communities/#{community.id}/ical"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('text/calendar')
      expect(response.body).to include('BEGIN:VCALENDAR')
      expect(response.body).to include('Common Dinner')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Communities API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/communities/:id/hosts' do
    it 'returns active adult residents ordered by unit' do
      adult = create(:resident, community: community, unit: unit, multiplier: 2, active: true)
      child = create(:resident, community: community, unit: unit, multiplier: 1, active: true)
      inactive = create(:resident, community: community, unit: unit, multiplier: 2, active: false,
                                   can_cook: false, email: nil)

      get "/api/v1/communities/#{community.id}/hosts", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      host_ids = body.pluck(0)
      expect(host_ids).to include(resident.id)
      expect(host_ids).to include(adult.id)
      expect(host_ids).not_to include(child.id)
      expect(host_ids).not_to include(inactive.id)
    end

    it 'returns 401 without a token' do
      get "/api/v1/communities/#{community.id}/hosts"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/communities/:id/birthdays' do
    it 'returns residents with birthdays in the target month' do
      march_bday = create(:resident, community: community, unit: unit,
                                     birthday: Date.new(1990, 3, 15))
      create(:resident, community: community, unit: unit,
                        birthday: Date.new(1985, 7, 20))

      get "/api/v1/communities/#{community.id}/birthdays", params: {
        token: token, start: '2026-03-01'
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      names = body.pluck('title')
      expect(names.join).to include(march_bday.name.split[0])
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
    # date, not shifted. This tests the full pipeline: controller → serializer.
    it 'returns birthdays on the correct date (not shifted by a day)' do
      create(:resident, community: community, unit: unit,
                        birthday: Date.new(1990, 4, 20))

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      birthdays = body['birthdays']
      expect(birthdays).not_to be_empty

      bday_start = birthdays.first['start']
      # The birthday should be April 20, not April 21
      expect(bday_start).to include('2026-04-20')
    end

    # Regression: malformed date params must return 400, not crash with 500.
    it 'returns 400 for a malformed date parameter' do
      get "/api/v1/communities/#{community.id}/calendar/not-a-date", params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Invalid date')
    end

    it 'includes January birthdays when viewing January calendar (year boundary)' do
      create(:resident, community: community, unit: unit, birthday: Date.new(1990, 1, 15))

      get "/api/v1/communities/#{community.id}/calendar/2026-01-15", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['birthdays']).not_to be_empty
    end

    it 'includes December birthdays when viewing December calendar (year boundary)' do
      create(:resident, community: community, unit: unit, birthday: Date.new(1990, 12, 20))

      get "/api/v1/communities/#{community.id}/calendar/2025-12-15", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['birthdays']).not_to be_empty
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

    # The full pipeline for a birthday appearing or disappearing, against a
    # real cache: the calendar response is cached per month, so setting or
    # clearing a birthday only shows up if the model callback invalidates
    # the affected month. The test env cache is a null store, so these swap
    # in a MemoryStore — without invalidation they would fail on stale data.
    describe 'birthday set or cleared, against a real cache' do
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
    end

    it 'returns a fresh 200 with new ETag after invalidation' do
      create(:meal, community: community, date: Date.new(2026, 4, 10))

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
      first_etag = response.headers['ETag']

      # Simulate a mutation that would invalidate the calendar cache
      community.invalidate_calendar_cache(Date.new(2026, 4, 10))
      create(:meal, community: community, date: Date.new(2026, 4, 17))

      get "/api/v1/communities/#{community.id}/calendar/2026-04-15",
          params: { token: token }, headers: { 'If-None-Match' => first_etag }

      expect(response).to have_http_status(:ok)
      expect(response.headers['ETag']).not_to eq(first_etag)
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

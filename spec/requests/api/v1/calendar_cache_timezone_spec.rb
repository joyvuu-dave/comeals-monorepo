# frozen_string_literal: true

require 'rails_helper'

# The month payload carries the community's time zone (added 2026-08-25 so
# a changed zone reaches open tabs). The month is cached under a version
# read from the tables it is drawn from, plus today's date. `communities`
# was not one of them, so after a zone change the push told every tab to
# fetch the month again, and the server answered from the entry built
# before the change, for up to an hour. Fixed in a79b1604: the version
# now reads communities.updated_at. Against a real cache, through the API.
RSpec.describe 'the calendar cache after a time zone change' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def month_timezone
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.parsed_body['timezone']
  end

  it 'serves the new zone on the next request' do
    expect(month_timezone).to eq('America/Los_Angeles')

    community.update!(timezone: 'America/New_York')

    expect(month_timezone).to eq('America/New_York')
  end

  it 'stores the month under the key for its year and month' do
    month_timezone

    expect(Rails.cache.exist?(community.calendar_cache_key(2026, 4))).to be(true)
    expect(Rails.cache.exist?(community.calendar_cache_key(2026, 3))).to be(false)
  end

  # CLAUDE.md, money rule 8: the month is cached for one hour.
  it 'keeps the month for one hour' do
    travel_to(Time.zone.local(2026, 4, 15, 12, 0)) { month_timezone }
    key = community.calendar_cache_key(2026, 4)

    travel_to(Time.zone.local(2026, 4, 15, 12, 59)) { expect(Rails.cache.exist?(key)).to be(true) }
    travel_to(Time.zone.local(2026, 4, 15, 13, 1)) { expect(Rails.cache.exist?(key)).to be(false) }
  end

  # The `timezone` field is the column, the same whether or not the request
  # ran in the community zone. An event's start is written out in the
  # request's zone, so that is what shows the bearer request got the zone.
  it 'reads the community zone for a request signed in with a bearer token too' do
    community.update!(timezone: 'Asia/Tokyo')
    tokyo = ActiveSupport::TimeZone['Asia/Tokyo']
    create(:event, community: community, start_date: tokyo.local(2026, 4, 15, 19),
                   end_date: tokyo.local(2026, 4, 15, 21))

    get "/api/v1/communities/#{community.id}/calendar/2026-04-15",
        headers: { 'Authorization' => "Bearer #{JwtAuth.encode(resident)}" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['timezone']).to eq('Asia/Tokyo')
    expect(response.parsed_body['events'].pluck('start')).to eq(['2026-04-15T19:00:00.000+09:00'])
  end
end

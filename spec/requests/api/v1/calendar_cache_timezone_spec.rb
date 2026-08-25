# frozen_string_literal: true

require 'rails_helper'

# The month payload carries the community's time zone (added 2026-08-25 so
# a changed zone reaches open tabs). The month is cached under a version
# read from seven tables plus today's date — and `communities` is not one
# of them. So the push tells every tab to fetch the month again, and the
# server answers from the entry built before the change, for up to an
# hour. Against a real cache, through the API.
RSpec.describe 'the calendar cache after a time zone change' do
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
end

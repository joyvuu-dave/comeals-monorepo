# frozen_string_literal: true

require 'rails_helper'

# Every API request runs in the community's zone (ApiController
# #set_community_timezone). No public action shows a time in Time.zone
# today, so a controller drawn for this spec answers with the zone it ran
# in. Until 2026-11-11 a request with no token ran in the app's zone
# (America/Los_Angeles), and a public action added later that showed a
# time would have shown it in that zone.
RSpec.describe 'ApiController#set_community_timezone' do
  let(:community) { create(:community, timezone: 'Asia/Tokyo') }
  let(:resident) { create(:resident, community: community) }

  before do
    stub_const('ZoneShowController', Class.new(ApiController) do
      def show = render(json: { zone: Time.zone.name })
    end)
  end

  def zone_seen(**)
    # with_routing ends the request session with the block, so the answer
    # is read inside it.
    with_routing do |routes|
      routes.draw { get '/api/zone' => 'zone_show#show' }
      get('/api/zone', **)
      response.parsed_body.fetch('zone')
    end
  end

  it 'runs a request with no token in the community zone' do
    community

    expect(zone_seen).to eq('Asia/Tokyo')
  end

  it 'runs a request whose token signs no one in, in the community zone' do
    community

    expect(zone_seen(params: { token: 'not-a-token' })).to eq('Asia/Tokyo')
  end

  it 'runs a signed-in request in the community zone' do
    token = JwtAuth.encode(resident)

    expect(zone_seen(headers: { 'Authorization' => "Bearer #{token}" })).to eq('Asia/Tokyo')
  end

  it 'runs in the app zone when there is no community yet' do
    expect(zone_seen).to eq('America/Los_Angeles')
  end
end

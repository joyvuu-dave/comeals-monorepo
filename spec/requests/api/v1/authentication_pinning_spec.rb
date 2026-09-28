# frozen_string_literal: true

require 'rails_helper'

# ADR 0002: authentication is the one boundary the API actually keeps. Every
# /api/v1 route needs a signed-in resident, except the short list of public
# routes below. The rest is read from routes.rb, not typed here, so a new
# route is covered the day it is added, and a stray `only:`/`except:` on a
# controller's `before_action :authenticate` fails a test.
#
# Auth runs before any record lookup, so a nonexistent id still yields 401,
# never 404. That is why every placeholder in a path can be filled with 1.
RSpec.describe 'API authentication boundary' do
  # Anyone may call these with no sign-in: signing in, resetting a
  # password, the two iCal feeds a calendar app polls, and the version
  # check. Each is [verb, path] as routes.rb draws it.
  def self.public_routes
    [
      %w[POST /api/v1/residents/token],
      %w[POST /api/v1/residents/password-reset],
      %w[POST /api/v1/residents/password-reset/:token],
      %w[GET /api/v1/residents/name/:token],
      %w[GET /api/v1/residents/:id/ical],
      %w[GET /api/v1/communities/:id/ical],
      %w[GET /api/v1/version]
    ]
  end

  def self.api_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix('(.:format)')
      [route.verb, path] if path.start_with?('/api/v1/')
    end
  end

  def filled(path)
    path.gsub(':date', '2026-01-01').gsub(/:\w+/, '1')
  end

  it 'names only public routes that exist' do
    expect(self.class.api_routes).to include(*self.class.public_routes)
  end

  (api_routes - public_routes).each do |verb, path|
    describe "#{verb} #{path}" do
      it 'returns 401 with no token' do
        public_send(verb.downcase, filled(path))
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 with a garbage token' do
        public_send(verb.downcase, filled(path), params: { token: 'not-a-real-token' })
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # The other half of the list: a route named public really is. The iCal
  # feeds look up their record first, so they get real ids.
  describe 'the public routes' do
    let(:community) { create(:community) }
    let(:resident) { create(:resident, community: community, unit: create(:unit, community: community)) }

    public_routes.each do |verb, path|
      it "#{verb} #{path} answers without a token" do
        url = filled(path.sub('/residents/:id/', "/residents/#{resident.id}/")
                         .sub('/communities/:id/', "/communities/#{community.id}/"))

        public_send(verb.downcase, url)

        expect(response).not_to have_http_status(:unauthorized)
      end
    end
  end
end

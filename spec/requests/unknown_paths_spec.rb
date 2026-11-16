# frozen_string_literal: true

require 'rails_helper'

# The resident site answers 200 only for the app's pages, the ones in
# app/frontend/src/routes.json, and 404 with the plain 404 page for
# every other address (challenge 34, ADR 0016). The admin site and the
# API answer their own 404s and are not part of this.
RSpec.describe 'Addresses that are not pages of the app' do
  def expect_plain_404
    expect(response).to have_http_status(:not_found)
    expect(response.content_type).to start_with('text/html')
    expect(response.body).to include("The page you were looking for doesn't exist (404)")
    expect(response.body).not_to include('<div id="root">')
  end

  # What Lighthouse and other tools ask for (challenge 34), what scanners
  # ask for that the scanner block lets through, typos, and paths with
  # more parts than any page has.
  [
    '/.well-known/security.txt',
    '/.well-known/apple-app-site-association',
    '/.well-known/change-password',
    '/.well-known',
    '/sitemap.xml',
    '/foo.json',
    '/settings.py',
    '/docker-compose.yaml',
    '/calnedar',
    '/login',
    '/calendar',
    '/calendar/all',
    '/calendar/all/2026-11-01/a/b/c/d',
    '/meals/42',
    '/meals/42/edit/nothing',
    '/reset-password/a-token-from-an-old-email',
    '/a/b/c/d'
  ].each do |path|
    it "answers #{path} with 404 and the plain 404 page" do
      get path

      expect_plain_404
    end
  end

  [
    '/',
    '/reset-password',
    '/confirm-email',
    '/calendar/all/2026-11-01',
    '/calendar/all/2026-11-01/events/new',
    '/calendar/all/2026-11-01/rotations/show/10',
    '/meals/42/edit',
    '/meals/42/edit/history'
  ].each do |path|
    it "answers the page #{path} with 200 and the app" do
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<div id="root">')
    end
  end

  # React Router ignores case and the slashes at the end, and the app
  # adds a slash at the end of every address (TrailingSlash in index.jsx).
  it 'treats an address the way the app does: any case, with or without slashes at the end' do
    %w[/calendar/all/2026-11-01/ /CALENDAR/all/2026-11-01 /meals/42/edit/history// /Reset-Password/].each do |path|
      get path

      expect(response).to have_http_status(:ok), "expected 200 for #{path}, got #{response.status}"
    end
  end

  it 'answers a HEAD request the same as a GET' do
    head '/foo.json'
    expect(response).to have_http_status(:not_found)

    head '/calendar/all/2026-11-01'
    expect(response).to have_http_status(:ok)
  end

  # A page missing from the list and then added back must show at once,
  # not after a browser or a proxy lets a kept 404 go.
  it 'tells browsers and proxies not to keep the 404' do
    get '/foo.json'

    expect(response.headers['Cache-Control']).to eq('no-store')
  end

  it 'gives a person a way back into the app' do
    get '/calnedar'

    expect(response.parsed_body.css('a[href="/"]')).not_to be_empty
  end

  it 'answers the 404 without a database query' do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { get '/a/b/c/d' }

    expect(response).to have_http_status(:not_found)
    expect(queries).to eq([])
  end

  describe 'what does not change' do
    it 'leaves the admin site to answer its own 404s' do
      host! 'admin.example.com'

      expect { get '/no-such-admin-page' }.to raise_error(ActionController::RoutingError)
    end

    it 'leaves unknown /api/ paths to the router' do
      expect { get '/api/v1/no-such-endpoint' }.to raise_error(ActionController::RoutingError)
    end

    it 'still refuses scanner paths with a 403 before the router runs' do
      get '/.env'

      expect(response).to have_http_status(:forbidden)
    end

    it 'still sends files that are in public/' do
      get '/robots.txt'

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('text/plain')
    end
  end
end

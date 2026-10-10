# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Routing' do
  describe 'CORS removal' do
    it 'does not return Access-Control-Allow-Origin headers on API requests' do
      get '/api/v1/version'
      expect(response.headers['Access-Control-Allow-Origin']).to be_nil
    end

    it 'does not return Access-Control-Allow-Origin headers on SPA requests' do
      get '/'
      expect(response.headers['Access-Control-Allow-Origin']).to be_nil
    end
  end

  describe 'ActiveAdmin on admin subdomain' do
    it 'routes admin subdomain to ActiveAdmin login, not the SPA' do
      host! 'admin.example.com'
      get '/login'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="admin_user_email"')
      expect(response.body).not_to include('<div id="root">')
    end

    it 'does not serve ActiveAdmin on the main domain' do
      get '/login'
      # Without admin subdomain, /login falls through to SPA catch-all
      expect(response.body).to include('<div id="root">')
    end
  end

  describe 'SPA catch-all on the admin subdomain (issue #18)' do
    it 'raises a routing error for unknown GET paths instead of serving the SPA' do
      host! 'admin.example.com'
      expect { get '/no-such-admin-page' }.to raise_error(ActionController::RoutingError)
    end

    it 'still serves the SPA for deep links on non-admin subdomains' do
      host! 'www.example.com'
      get '/calendar/meals/2026-04-14'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<div id="root">')
    end

    it 'still keeps unknown /api/ paths out of the catch-all' do
      host! 'www.example.com'
      expect { get '/api/v1/no-such-endpoint' }.to raise_error(ActionController::RoutingError)
    end

    it 'still keeps /letter_opener paths out of the catch-all' do
      # The letter_opener engine is only mounted in development, so in test
      # the path must fall through to a routing error, not the SPA.
      host! 'www.example.com'
      expect { get '/letter_opener' }.to raise_error(ActionController::RoutingError)
    end
  end

  describe 'missing files under the built asset folders' do
    # The static file server answers every file that is there before the
    # router runs. So a request that reaches the router asks for a file a
    # deploy removed, or one that never existed. No app page lives under
    # these two folders, so the answer is the plain 404 page.
    %w[/assets/gone-Ab12Cd34.css /vite-assets/show-Ab12Cd34.js /vite-assets/logo.png /assets].each do |path|
      it "answers #{path} with the plain 404 page when the file is not there" do
        host! 'www.example.com'
        get path
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to start_with('text/html')
        expect(response.body).to include("The page you were looking for doesn't exist (404)")
      end
    end

    it 'answers the same on the admin host, where the admin stylesheets live under /assets/' do
      host! 'admin.example.com'
      get '/assets/active_admin-Ab12Cd34.css'
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("The page you were looking for doesn't exist (404)")
    end

    it 'still serves the SPA at a path that only starts like an asset folder' do
      host! 'www.example.com'
      get '/assets-list'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<div id="root">')
    end
  end

  describe 'API routes remain functional' do
    it 'routes /api/v1/version to site#version' do
      get '/api/v1/version'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('application/json')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'FallbackController' do
  describe 'GET / (root)' do
    it 'serves index.html with text/html content type' do
      get '/'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('text/html')
      expect(response.body).to include('<div id="root">')
    end
  end

  describe 'GET /*path (SPA catch-all)' do
    it 'serves index.html for frontend routes' do
      get '/calendar/meals/2026-04-14'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('text/html')
      expect(response.body).to include('<div id="root">')
    end

    it 'does not catch /api/ routes' do
      get '/api/v1/version'
      expect(response.content_type).to start_with('application/json')
    end

    it 'does not catch /admin routes on admin subdomain' do
      host! 'admin.example.com'
      get '/login'
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('<div id="root">')
    end
  end

  describe 'GET /.vite/manifest.json' do
    it 'serves the Vite manifest as JSON' do
      get '/.vite/manifest.json'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('application/json')
      expect { response.parsed_body }.not_to raise_error
    end
  end
end

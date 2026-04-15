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
    it 'routes admin subdomain to ActiveAdmin login' do
      host! 'admin.example.com'
      get '/login'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="admin_user_email"')
    end

    it 'routes admin subdomain login to Devise session' do
      host! 'admin.example.com'
      get '/login'
      expect(response).to have_http_status(:ok)
    end

    it 'does not serve ActiveAdmin on the main domain' do
      get '/login'
      # Without admin subdomain, /login falls through to SPA catch-all
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

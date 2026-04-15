# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Routing' do
  describe 'CORS removal' do
    it 'does not return Access-Control-Allow-Origin headers' do
      get '/api/v1/version'
      expect(response.headers['Access-Control-Allow-Origin']).to be_nil
    end

    it 'does not include CORS headers on SPA requests either' do
      get '/'
      expect(response.headers['Access-Control-Allow-Origin']).to be_nil
    end
  end

  describe 'ActiveAdmin at /admin path (not subdomain)' do
    it 'routes /admin to the dashboard' do
      get '/admin'
      # Redirects to login when not authenticated
      expect(response).to redirect_to('/admin/login')
    end

    it 'routes /admin/login to Devise session' do
      get '/admin/login'
      expect(response).to have_http_status(:ok)
    end

    it 'routes /admin-logout to application#admin_logout' do
      get '/admin-logout'
      # admin_logout redirects (to admin login or root), confirming the route works
      expect(response).to have_http_status(:redirect)
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

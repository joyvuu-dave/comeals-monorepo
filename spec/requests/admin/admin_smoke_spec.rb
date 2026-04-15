# frozen_string_literal: true

require 'rails_helper'

# Smoke tests for ActiveAdmin pages. These verify that the admin interface
# actually renders — styled, functional, and error-free — after routing and
# configuration changes. The permit_params specs test data flow; these test
# that the pages themselves work.
RSpec.describe 'Admin smoke tests' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before { host! 'admin.example.com' }

  describe 'login page' do
    it 'renders the login form' do
      get '/login'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="admin_user_email"')
      expect(response.body).to include('id="admin_user_password"')
    end

    it 'references Sprockets stylesheets that resolve to CSS' do
      get '/login'
      css_hrefs = response.body.scan(/href="([^"]*active_admin[^"]*\.css[^"]*)"/).flatten
      expect(css_hrefs).not_to be_empty, 'login page should reference active_admin CSS'

      css_hrefs.each do |href|
        get href
        expect(response).to have_http_status(:ok), "#{href} returned #{response.status}"
        expect(response.content_type).to include('text/css'),
                                         "#{href} returned #{response.content_type}, expected text/css"
      end
    end

    it 'references Sprockets javascripts that resolve to JS' do
      get '/login'
      js_srcs = response.body.scan(/src="([^"]*active_admin[^"]*\.js[^"]*)"/).flatten
      expect(js_srcs).not_to be_empty, 'login page should reference active_admin JS'

      js_srcs.each do |src|
        get src
        expect(response).to have_http_status(:ok), "#{src} returned #{response.status}"
        expect(response.content_type).to include('javascript'),
                                         "#{src} returned #{response.content_type}, expected javascript"
      end
    end
  end

  describe 'login flow' do
    it 'authenticates via sign_in and loads the dashboard' do
      sign_in admin_user
      get '/'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Dashboard')
      expect(response.body).to include('id="active_admin_content"')
    end

    it 'rejects invalid credentials' do
      post '/login', params: {
        admin_user: { email: admin_user.email, password: 'wrong' }
      }
      expect(response).to have_http_status(:unprocessable_content)
                      .or have_http_status(:ok)
      expect(response.body).to include('id="admin_user_email"')
    end
  end

  describe 'dashboard (authenticated)' do
    before { sign_in admin_user }

    it 'renders with ActiveAdmin layout' do
      get '/'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="active_admin_content"')
    end

    it 'references stylesheets that resolve to CSS (not SPA HTML)' do
      get '/'
      css_hrefs = response.body.scan(/href="([^"]*\.css[^"]*)"/).flatten
                          .select { |h| h.start_with?('/assets/') }

      css_hrefs.each do |href|
        get href
        expect(response).to have_http_status(:ok), "#{href} returned #{response.status}"
        expect(response.content_type).not_to include('text/html'),
                                             "#{href} served HTML instead of CSS — " \
                                             'SPA catch-all is swallowing asset requests'
      end
    end
  end

  describe 'resource pages (authenticated)' do
    before { sign_in admin_user }

    it 'renders the residents index' do
      create(:resident, community: community, unit: create(:unit, community: community))
      get '/residents'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="active_admin_content"')
    end

    it 'renders the meals index' do
      get '/meals'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="active_admin_content"')
    end
  end

  describe 'subdomain isolation' do
    it 'admin routes are NOT accessible without admin subdomain' do
      host! 'www.example.com'
      get '/login'
      # Without admin subdomain, /login should fall through to SPA catch-all
      expect(response.body).to include('<div id="root">')
    end
  end
end

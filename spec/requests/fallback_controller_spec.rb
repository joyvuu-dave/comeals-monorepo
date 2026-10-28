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

    # send_file's own default is "attachment", which makes a browser
    # save the app as a file instead of opening it.
    it 'serves the page to be shown, not saved' do
      get '/'
      expect(response.headers['Content-Disposition']).to start_with('inline')
    end
  end

  describe 'GET /*path (SPA catch-all)' do
    it 'serves index.html for frontend routes' do
      get '/calendar/meals/2026-04-14'
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('text/html')
      expect(response.body).to include('<div id="root">')
    end
  end

  # The page carries the keys of the app that sends it, not of the app
  # that built it (#257). PageSettings has the rules.
  describe 'the keys in the page' do
    it "carries this app's Pusher key" do
      stub_const('ENV', ENV.to_h.merge('PUSHER_KEY' => 'this-apps-key').except('INTEGRATION_SERVER', 'COMEALS_STAGING'))

      get '/calendar/meals/2026-04-14'

      tags = response.parsed_body.css('meta[name="comeals-pusher-key"]')
      expect(tags.pluck('content')).to eq(['this-apps-key'])
    end
  end

  # The static file server would send the build's file as it is on disk,
  # without this app's keys. The page lives at /.
  describe 'GET /index.html' do
    it 'sends the browser to /' do
      get '/index.html'

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers['Location']).to eq('/')
    end

    it 'keeps the query string' do
      get '/index.html?from=home-screen'

      expect(response.headers['Location']).to eq('/?from=home-screen')
    end
  end

  # What the catch-all must not answer (an /api/ path, anything on the
  # admin host) is checked in routing_spec.rb.
end

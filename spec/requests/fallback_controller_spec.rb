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

  # What the catch-all must not answer (an /api/ path, anything on the
  # admin host) is checked in routing_spec.rb.
end

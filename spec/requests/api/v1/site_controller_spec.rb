# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Site API' do
  describe 'GET /api/v1/version' do
    it 'returns version 0 outside production' do
      get '/api/v1/version'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['version']).to eq(0)
    end

    it 'reports staging: false when COMEALS_STAGING is not set' do
      get '/api/v1/version'

      expect(response.parsed_body['staging']).to be(false)
    end

    # The aggressive smoke test refuses to run against any server that
    # does not say staging here — this flag is its only lock.
    it 'reports staging: true when COMEALS_STAGING is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('COMEALS_STAGING').and_return('1')

      get '/api/v1/version'

      expect(response.parsed_body['staging']).to be(true)
    end

    it 'reports the deployed commit when HEROKU_SLUG_COMMIT is set' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('HEROKU_SLUG_COMMIT', nil).and_return('abc123')

      get '/api/v1/version'

      expect(response.parsed_body['commit']).to eq('abc123')
    end

    context 'when in production' do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
        allow(ENV).to receive(:[]).and_call_original
      end

      it 'returns the parsed Heroku release number when HEROKU_RELEASE_VERSION is set' do
        allow(ENV).to receive(:[]).with('HEROKU_RELEASE_VERSION').and_return('v42')

        get '/api/v1/version'

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['version']).to eq(42)
      end

      it 'falls back to 1 when HEROKU_RELEASE_VERSION is missing' do
        allow(ENV).to receive(:[]).with('HEROKU_RELEASE_VERSION').and_return(nil)

        get '/api/v1/version'

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['version']).to eq(1)
      end

      it 'falls back to 1 when HEROKU_RELEASE_VERSION is malformed' do
        allow(ENV).to receive(:[]).with('HEROKU_RELEASE_VERSION').and_return('not-a-version')

        get '/api/v1/version'

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['version']).to eq(1)
      end
    end
  end
end

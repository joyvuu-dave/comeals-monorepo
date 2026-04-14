# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Site API' do
  describe 'GET /api/v1/version' do
    it 'returns version 0 outside production' do
      get '/api/v1/version'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['version']).to eq(0)
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

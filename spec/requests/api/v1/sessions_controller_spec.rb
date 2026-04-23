# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Sessions API' do
  let(:community) { create(:community, slug: 'testcom') }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) do
    create(:resident, community: community, unit: unit, email: 'alice@example.com',
                      password: 'correctpassword')
  end

  # Legacy Key (created by the factory after(:create) hook) — represents a
  # session issued before the JWT migration.
  let(:legacy_key) { resident.keys.first }

  def legacy_auth(key) = { 'Authorization' => "Bearer #{key.token}" }
  def jwt_auth(res)    = { 'Authorization' => "Bearer #{JwtAuth.encode(res)}" }

  describe 'DELETE /api/v1/sessions/current' do
    context 'with a legacy Key session' do
      it 'destroys the key row' do
        legacy_key
        other_key = resident.keys.create!

        expect { delete '/api/v1/sessions/current', headers: legacy_auth(legacy_key) }
          .to change(Key, :count).by(-1)

        expect(response).to have_http_status(:ok)
        expect(Key.exists?(legacy_key.id)).to be(false)
        expect(Key.exists?(other_key.id)).to be(true)
      end
    end

    context 'with a JWT session' do
      it 'succeeds without touching the keys table (no server-side state exists)' do
        expect { delete '/api/v1/sessions/current', headers: jwt_auth(resident) }
          .not_to change(Key, :count)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('Signed out.')
      end
    end

    it 'returns 401 without a token' do
      delete '/api/v1/sessions/current'
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'Authentication paths' do
    it 'authenticates a freshly-issued JWT' do
      get '/api/v1/residents/id', headers: jwt_auth(resident)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'authenticates a legacy Key via Bearer header (grandfather clause)' do
      get '/api/v1/residents/id', headers: legacy_auth(legacy_key)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'still accepts a legacy Key passed as a query parameter' do
      get '/api/v1/residents/id', params: { token: legacy_key.token }
      expect(response).to have_http_status(:ok)
    end

    it "rejects a JWT whose iat predates the resident's keys_valid_since" do
      token = JwtAuth.encode(resident)
      resident.update_column(:keys_valid_since, 1.hour.from_now)

      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/v1/residents/token (login)' do
    it 'returns a JWT that authenticates as this resident' do
      post '/api/v1/residents/token', params: {
        email: 'alice@example.com',
        password: 'correctpassword'
      }

      expect(response).to have_http_status(:ok)
      jwt = response.parsed_body['token']
      expect(JwtAuth.authenticate(jwt)).to eq(resident)
    end

    it 'does not create a Key row (JWTs are stateless)' do
      expect do
        post '/api/v1/residents/token', params: {
          email: 'alice@example.com',
          password: 'correctpassword'
        }
      end.not_to change(Key, :count)
    end
  end
end

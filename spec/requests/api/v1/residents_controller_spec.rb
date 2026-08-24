# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Residents API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) do
    create(:resident, community: community, unit: unit, email: 'alice@example.com',
                      password: 'correctpassword')
  end
  let(:token) { resident.keys.first.token }

  # ---------------------------------------------------------------------------
  # POST /api/v1/residents/token (login)
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/residents/token' do
    it 'returns a JWT and community info on valid credentials' do
      post '/api/v1/residents/token', params: {
        email: 'alice@example.com',
        password: 'correctpassword'
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      # The returned token is a JWT that authenticates as this resident.
      expect(JwtAuth.authenticate(body['token'])).to eq(resident)
      expect(body['community_id']).to eq(community.id)
      expect(body['resident_id']).to eq(resident.id)
    end

    it 'is case-insensitive on email' do
      post '/api/v1/residents/token', params: {
        email: 'ALICE@EXAMPLE.COM',
        password: 'correctpassword'
      }

      expect(response).to have_http_status(:ok)
    end

    it 'returns 400 with wrong password' do
      post '/api/v1/residents/token', params: {
        email: 'alice@example.com',
        password: 'wrongpassword'
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Incorrect password')
    end

    it 'returns 400 with unknown email' do
      post '/api/v1/residents/token', params: {
        email: 'nobody@example.com',
        password: 'anything'
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('No resident with email')
    end

    it 'returns 400 with blank email' do
      post '/api/v1/residents/token', params: { email: '', password: 'anything' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Email required.')
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/residents/id
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/residents/id' do
    it "returns the authenticated resident's ID" do
      get '/api/v1/residents/id', params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'returns 401 without a token' do
      get '/api/v1/residents/id'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/residents/name/:token
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/residents/name/:token' do
    it 'returns the resident name for a valid reset token' do
      resident.update!(reset_password_token: 'valid-token-123', reset_password_sent_at: Time.current)

      get '/api/v1/residents/name/valid-token-123'

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['name']).to be_present
    end

    it 'returns 400 for an invalid reset token' do
      get '/api/v1/residents/name/bogus-token'

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('incorrect or expired')
    end

    it 'returns 400 for an expired reset token' do
      resident.update!(reset_password_token: 'expired-token', reset_password_sent_at: 25.hours.ago)

      get '/api/v1/residents/name/expired-token'

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end

    it 'does not clear the expired token (GET must be side-effect-free)' do
      resident.update!(reset_password_token: 'stale-token', reset_password_sent_at: 25.hours.ago)

      get '/api/v1/residents/name/stale-token'

      resident.reload
      expect(resident.reset_password_token).to eq('stale-token')
      expect(resident.reset_password_sent_at).to be_present
    end

    it 'returns 400 when reset_password_sent_at is nil' do
      resident.update_columns(reset_password_token: 'orphan-token', reset_password_sent_at: nil)

      get '/api/v1/residents/name/orphan-token'

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/residents/password-reset/:token (password_new)
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/residents/password-reset/:token' do
    it 'sets a new password with a valid reset token' do
      resident.update!(reset_password_token: 'reset-token-456', reset_password_sent_at: Time.current)

      post '/api/v1/residents/password-reset/reset-token-456', params: {
        password: 'newpassword123'
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Password updated!')

      # Verify new password works
      expect(resident.reload.authenticate('newpassword123')).to be_truthy
    end

    it 'returns 400 for an invalid reset token' do
      post '/api/v1/residents/password-reset/bogus-token', params: {
        password: 'newpassword123'
      }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'password reset, the other branches' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit, email: 'ann@example.com') }

    it 'answers 400 when the reset token could not be saved' do
      allow(PasswordReset).to receive(:request).and_return(:save_failed)

      post '/api/v1/residents/password-reset', params: { email: resident.email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Error. Please try again.')
    end

    # A blank password is a feature the community asked for, not a gap:
    # some residents log in with email alone. The whole path must work.
    it 'accepts a blank new password, and the resident can then log in with email alone' do
      resident.update!(reset_password_token: 'reset-token-789', reset_password_sent_at: Time.current)

      post '/api/v1/residents/password-reset/reset-token-789', params: { password: '' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Password updated!')
      expect(resident.reload.reset_password_token).to be_nil

      post '/api/v1/residents/token', params: { email: resident.email, password: '' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['token']).to be_present

      post '/api/v1/residents/token', params: { email: resident.email, password: 'not blank' }
      expect(response).to have_http_status(:bad_request)
    end

    it 'treats a missing password the same as a blank one' do
      resident.update!(reset_password_token: 'reset-token-790', reset_password_sent_at: Time.current)

      post '/api/v1/residents/password-reset/reset-token-790'

      expect(response).to have_http_status(:ok)
      expect(resident.reload.authenticate('')).to be_truthy
    end
  end
end

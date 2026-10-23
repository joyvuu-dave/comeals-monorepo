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
    # The shape public/api.md shows. The SPA keeps the name and the zone
    # in its login cookie: the name for the header, the zone for every
    # time it shows.
    it 'returns a JWT and community info on valid credentials, in the shape api.md shows' do
      resident.update!(name: 'Alice Walker')

      post '/api/v1/residents/token', params: {
        email: 'alice@example.com',
        password: 'correctpassword'
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      # The returned token is a JWT that authenticates as this resident.
      expect(JwtAuth.authenticate(body['token'])).to eq(resident)
      expect(body.except('token')).to eq('community_id' => community.id, 'resident_id' => resident.id,
                                         'username' => 'Alice', 'timezone' => 'America/Los_Angeles')
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

    # A request made by hand can leave the password field out. For a
    # resident with a password that is a wrong password, in the same words.
    it 'returns 400 with no password field at all' do
      post '/api/v1/residents/token', params: { email: 'alice@example.com' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Incorrect password')
    end

    it 'returns 400 with unknown email' do
      post '/api/v1/residents/token', params: {
        email: 'nobody@example.com',
        password: 'anything'
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('No resident with email')
    end

    # A form or query string can send email[]=... . It is not an email,
    # and it must get the same 400 as one nobody has, not a 500.
    it 'returns 400 with an email sent as a list' do
      post '/api/v1/residents/token', params: { email: ['alice@example.com'], password: 'correctpassword' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to start_with('No resident with email')
    end

    it 'returns 400 with blank email' do
      post '/api/v1/residents/token', params: { email: '', password: 'anything' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Email required.')
    end

    # A request made by hand can leave the email field out. It gets the
    # same words as an empty email.
    it 'returns 400 with no email field at all' do
      post '/api/v1/residents/token', params: { password: 'anything' }

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
  # POST /api/v1/residents/password-reset/name
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/residents/password-reset/name' do
    it 'returns the resident name for a valid reset token' do
      give_reset_token(resident, token: 'valid-token-123', sent_at: Time.current)

      post '/api/v1/residents/password-reset/name', params: { reset_token: 'valid-token-123' }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['name']).to be_present
    end

    it 'returns 400 for an invalid reset token' do
      post '/api/v1/residents/password-reset/name', params: { reset_token: 'bogus-token' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Password reset link is incorrect or expired.')
    end

    it 'returns 400 for an expired reset token' do
      give_reset_token(resident, token: 'expired-token', sent_at: 25.hours.ago)

      post '/api/v1/residents/password-reset/name', params: { reset_token: 'expired-token' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end

    it 'does not clear the expired token (asking for the name changes nothing)' do
      give_reset_token(resident, token: 'stale-token', sent_at: 25.hours.ago)

      post '/api/v1/residents/password-reset/name', params: { reset_token: 'stale-token' }

      resident.reload
      expect(resident.reset_password_token_digest).to eq(PasswordReset.digest('stale-token'))
      expect(resident.reset_password_sent_at).to be_present
    end

    it 'returns 400 when reset_password_sent_at is nil' do
      give_reset_token(resident, token: 'orphan-token', sent_at: nil)

      post '/api/v1/residents/password-reset/name', params: { reset_token: 'orphan-token' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/residents/password-reset/new (password_new)
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/residents/password-reset/new' do
    it 'sets a new password with a valid reset token' do
      give_reset_token(resident, token: 'reset-token-456', sent_at: Time.current)

      post '/api/v1/residents/password-reset/new', params: {
        reset_token: 'reset-token-456', password: 'newpassword123'
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Password updated!')

      # Verify new password works
      expect(resident.reload.authenticate('newpassword123')).to be_truthy
    end

    it 'returns 400 for an invalid reset token' do
      post '/api/v1/residents/password-reset/new', params: {
        reset_token: 'bogus-token', password: 'newpassword123'
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Password reset link is incorrect or expired.')
    end
  end

  # Where a reset page loaded before 2026-10-23 sends the token: in the
  # path. Those tokens were all cleared, so the answer says to ask for a
  # new link, and it looks nothing up, even for a token that works.
  describe 'the reset requests of the page before 2026-10-23' do
    let(:retired) { 'This password reset link no longer works. Please request a new one.' }

    it 'answers the old name request with a 400 that says to ask for a new link' do
      token = give_reset_token(resident)

      get "/api/v1/residents/name/#{token}"

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => retired)
    end

    it 'answers the old new-password request with the same 400, and changes no password' do
      token = give_reset_token(resident)

      post "/api/v1/residents/password-reset/#{token}", params: { password: 'new one' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => retired)
      expect(resident.reload.authenticate('new one')).to be(false)
      expect(PasswordReset.resident_for(token)).to eq(resident)
    end
  end

  describe 'password reset, the other branches' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit, email: 'ann@example.com') }

    # A blank password is a feature the community asked for, not a gap:
    # some residents log in with email alone. The whole path must work.
    it 'accepts a blank new password, and the resident can then log in with email alone' do
      give_reset_token(resident, token: 'reset-token-789', sent_at: Time.current)

      post '/api/v1/residents/password-reset/new', params: { reset_token: 'reset-token-789', password: '' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Password updated!')
      expect(resident.reload.reset_password_token_digest).to be_nil

      post '/api/v1/residents/token', params: { email: resident.email, password: '' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['token']).to be_present

      post '/api/v1/residents/token', params: { email: resident.email, password: 'not blank' }
      expect(response).to have_http_status(:bad_request)
    end

    # A password has no rule, so it can never be why the save fails. Some
    # other field on the row is (here a blank name). The answer names that
    # field and says who can fix it, so the person does not go off to try
    # other passwords, which would all fail the same way (#105).
    it 'names the field that stops the save, not the password, and the link works once an admin fixes it' do
      give_reset_token(resident, token: 'reset-token-791', sent_at: Time.current)
      resident.update_columns(name: '')

      post '/api/v1/residents/password-reset/new', params: { reset_token: 'reset-token-791', password: 'new one' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq("Your password was not changed:\nName can't be blank\nPlease ask an admin to fix your account.")
      expect(resident.reload.reset_password_token_digest).to eq(PasswordReset.digest('reset-token-791'))
      expect(resident.authenticate('new one')).to be(false)

      resident.update_columns(name: 'Ann Lee')
      post '/api/v1/residents/password-reset/new', params: { reset_token: 'reset-token-791', password: 'new one' }

      expect(response).to have_http_status(:ok)
      expect(resident.reload.authenticate('new one')).to eq(resident)
    end

    it 'names every field that stops the save, one to a line' do
      give_reset_token(resident, token: 'reset-token-792', sent_at: Time.current)
      resident.update_columns(name: '', birthday: community.today + 1)

      post '/api/v1/residents/password-reset/new', params: { reset_token: 'reset-token-792', password: 'new one' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq(
        "Your password was not changed:\nName can't be blank\nBirthday cannot be after today.\n" \
        'Please ask an admin to fix your account.'
      )
    end

    # The same row, on the "forgot password" request. The save fails on a
    # field the person cannot fix from here, so trying again would fail the
    # same way every time. No link is saved and no mail goes out.
    it 'names the field that stops the save of a reset link, and sends nothing' do
      resident.update_columns(name: '')

      expect { post '/api/v1/residents/password-reset', params: { email: resident.email } }
        .not_to(change { ActionMailer::Base.deliveries.count })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq("No reset link was sent:\nName can't be blank\nPlease ask an admin to fix your account.")
      expect(resident.reload.reset_password_token_digest).to be_nil
    end

    it 'treats a missing password the same as a blank one' do
      give_reset_token(resident, token: 'reset-token-790', sent_at: Time.current)

      post '/api/v1/residents/password-reset/new', params: { reset_token: 'reset-token-790' }

      expect(response).to have_http_status(:ok)
      expect(resident.reload.authenticate('')).to be_truthy
    end
  end
end

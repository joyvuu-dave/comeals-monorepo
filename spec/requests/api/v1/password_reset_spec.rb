# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/residents/password-reset' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit, email: 'sarah@example.com') }

  def request_reset(email:)
    post '/api/v1/residents/password-reset', params: { email: email }
  end

  describe 'successful password reset' do
    it 'returns 200 with a success message' do
      request_reset(email: 'sarah@example.com')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Check your email.')
    end

    it 'sets a reset_password_token on the resident' do
      expect { request_reset(email: 'sarah@example.com') }
        .to change { resident.reload.reset_password_token }.from(nil)
    end

    it 'sets reset_password_sent_at on the resident' do
      expect { request_reset(email: 'sarah@example.com') }
        .to change { resident.reload.reset_password_sent_at }.from(nil)
    end

    it 'sends a password reset email' do
      expect { request_reset(email: 'sarah@example.com') }
        .to change { ActionMailer::Base.deliveries.count }.by(1)
    end
  end

  describe 'email delivery failure' do
    before do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      allow(ResidentMailer).to receive(:password_reset_email).and_return(mail_double)
      allow(mail_double).to receive(:deliver_now).and_raise(Net::ReadTimeout)
    end

    it 'returns 503 with a helpful message' do
      request_reset(email: 'sarah@example.com')

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['message']).to include('email could not be sent')
    end

    it 'still saves the reset token so the user can retry' do
      request_reset(email: 'sarah@example.com')

      expect(resident.reload.reset_password_token).to be_present
    end

    it 'logs the error' do
      allow(Rails.logger).to receive(:error)

      request_reset(email: 'sarah@example.com')

      expect(Rails.logger).to have_received(:error).with(/Password reset email failed.*Net::ReadTimeout/)
    end
  end

  describe 'POST /api/v1/residents/password-reset/:token (password_new)' do
    before do
      resident.update!(reset_password_token: SecureRandom.urlsafe_base64,
                       reset_password_sent_at: Time.current)
    end

    it 'clears the reset_password_token after successful reset' do
      token = resident.reset_password_token
      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }

      expect(response).to have_http_status(:ok)
      expect(resident.reload.reset_password_token).to be_nil
    end

    it 'clears reset_password_sent_at after successful reset' do
      token = resident.reset_password_token
      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }

      expect(response).to have_http_status(:ok)
      expect(resident.reload.reset_password_sent_at).to be_nil
    end

    it 'prevents reuse of the same token' do
      token = resident.reset_password_token
      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }
      expect(response).to have_http_status(:ok)

      post "/api/v1/residents/password-reset/#{token}", params: { password: 'anotherpassword' }
      expect(response).to have_http_status(:bad_request)
    end

    # Regression test for BUG-4: password reset tokens must expire.
    it 'rejects a token older than 24 hours' do
      resident.update_columns(reset_password_sent_at: 25.hours.ago)
      token = resident.reset_password_token

      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end

    it 'accepts a token less than 24 hours old' do
      resident.update_columns(reset_password_sent_at: 23.hours.ago)
      token = resident.reset_password_token

      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }

      expect(response).to have_http_status(:ok)
    end

    it 'rejects a token when reset_password_sent_at is nil' do
      resident.update_columns(reset_password_sent_at: nil)
      token = resident.reset_password_token

      post "/api/v1/residents/password-reset/#{token}", params: { password: 'newpassword123' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('expired')
    end
  end

  describe 'validation errors' do
    it 'returns 400 when email is missing' do
      post '/api/v1/residents/password-reset', params: {}

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Email required.')
    end

    it 'returns 400 when no resident matches the email' do
      request_reset(email: 'nobody@example.com')

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('No resident with that email address.')
    end
  end
end

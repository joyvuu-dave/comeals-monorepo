# frozen_string_literal: true

require 'rails_helper'

# The Common House screen signs in on the resident form, with
# CommonHouseLogin::EMAIL and the password an admin set. The answers say
# what is wrong, as the resident answers do (docs/adr/0010).
RSpec.describe 'Signing in the Common House screen' do
  let!(:community) { create(:community, timezone: 'America/New_York') }
  let(:password) { 'a long shared password' }

  def sign_in(email: CommonHouseLogin::EMAIL, password: self.password)
    post '/api/v1/residents/token', params: { email: email, password: password }
  end

  describe 'with the login made in admin' do
    let!(:login) { create(:common_house_login, password: password) }

    # The web app keeps each field in a cookie (login.jsx). username is
    # what the headers show ("logout Common House"), and common_house
    # tells the page it is the shared screen.
    it 'answers a token for the Common House login, the community, and what the screen is called' do
      sign_in

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(JwtAuth.authenticate(body['token'])).to eq(login)
      expect(body.except('token')).to eq('community_id' => community.id, 'timezone' => 'America/New_York',
                                         'username' => 'Common House', 'common_house' => true)
    end

    # The screen is not a resident, so the answer has no resident id.
    it 'names no resident' do
      sign_in

      expect(response.parsed_body).not_to have_key('resident_id')
    end

    it 'takes the address in capitals and with spaces around it' do
      sign_in(email: "  #{CommonHouseLogin::EMAIL.upcase} ")

      expect(response).to have_http_status(:ok)
    end

    it 'refuses a wrong password' do
      sign_in(password: 'not the password')

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => 'Incorrect password')
    end

    it 'refuses no password, and a password sent as a list' do
      post '/api/v1/residents/token', params: { email: CommonHouseLogin::EMAIL }
      expect(response).to have_http_status(:bad_request)

      post '/api/v1/residents/token', params: { email: CommonHouseLogin::EMAIL, password: [password] }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it 'says so when no admin has made the login yet' do
    sign_in

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq('message' => 'The Common House login is not set up yet. Ask an admin.')
  end

  # Only admins set this password (decided 2026-11-01), so no reset link
  # is mailed for it, and there is no mailbox to mail it to.
  it 'sends no reset link for the Common House address, and says who sets the password' do
    create(:common_house_login, password: password)

    expect { post '/api/v1/residents/password-reset', params: { email: CommonHouseLogin::EMAIL } }
      .not_to have_enqueued_mail

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body)
      .to eq('message' => 'An admin sets the Common House password. Ask an admin to change it.')
  end
end

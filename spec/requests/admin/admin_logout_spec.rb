# frozen_string_literal: true

require 'rails_helper'

# The admin's logout link points at GET /admin-logout, a hand-written
# action (ActiveAdmin's own logout is a DELETE that the link cannot send).
RSpec.describe 'GET /admin-logout' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }

  before { host! 'admin.example.com' }

  it 'ends the session and sends the admin to the root' do
    sign_in admin_user
    get '/dashboard'
    expect(response).to have_http_status(:ok)

    get '/admin-logout'
    expect(response).to redirect_to('/')
    expect(response.cookies['remember_admin_user_token']).to be_nil

    get '/dashboard'
    expect(response).to redirect_to('/login')
  end
end

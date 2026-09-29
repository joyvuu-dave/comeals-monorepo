# frozen_string_literal: true

require 'rails_helper'

# A POST with a bad CSRF token (a bot, or a login tab left open past the
# session's life) goes back to the login page with a message instead of a
# 422 error page and a Bugsnag report.
RSpec.describe 'admin POST with a bad CSRF token' do
  before do
    create(:community)
    host! 'admin.example.com'
  end

  around do |example|
    was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = was
  end

  it 'redirects to the login page with a message' do
    post '/login', params: { admin_user: { email: 'a@example.com', password: 'x' } }

    expect(response).to redirect_to('/login')
    expect(flash[:alert]).to eq('Your session expired. Please try again.')
  end

  # The request did not come from a page this session was given, so the
  # session is not trusted any more: a signed-in admin is signed out.
  it 'ends the session of an admin who was signed in' do
    sign_in create(:admin_user, community: Community.instance)
    get '/'
    expect(response).to have_http_status(:ok)

    post '/units', params: { unit: { name: 'Z' } }
    expect(response).to redirect_to('/login')

    get '/'
    expect(response).to redirect_to('/login')
  end
end

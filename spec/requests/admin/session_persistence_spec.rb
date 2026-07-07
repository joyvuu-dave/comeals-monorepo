# frozen_string_literal: true

require 'rails_helper'

# One sign_in must authenticate a whole example, not just its first request.
# The app is api_only, so session middleware is added by hand in
# config/application.rb. A gap there meant the first response never set a
# session cookie: the first request was authenticated only by Warden's
# test-mode hook, and every later request in the same example silently
# redirected to the login page. See issue #19.
RSpec.describe 'Admin session persistence' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before { host! 'admin.example.com' }

  it 'keeps the admin signed in across two requests in one example' do
    sign_in admin_user

    get '/'
    expect(response).to have_http_status(:ok)

    get '/'
    expect(response).to have_http_status(:ok)
  end

  it 'ends the session on sign_out' do
    sign_in admin_user

    get '/'
    expect(response).to have_http_status(:ok)

    sign_out admin_user

    get '/'
    expect(response).to redirect_to('/login')
  end
end

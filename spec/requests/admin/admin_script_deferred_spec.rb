# frozen_string_literal: true

require 'rails_helper'

# The admin script is in <head>. A plain script there stops the browser
# from drawing the page until it has downloaded and run, and it is the
# largest file on every admin page. With `defer` it downloads while the
# page is read and runs just before DOMContentLoaded, which is when
# every handler in it starts anyway: they all wait for jQuery's
# $(function () { ... }). The one script written into an admin page
# (admin_users/passwords/edit.html.erb) uses no jQuery.
RSpec.describe 'The admin script tag' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }

  before { host! 'admin.example.com' }

  def admin_script_tags
    response.parsed_body.css('script[src*="active_admin"]')
  end

  it 'is deferred on the login page' do
    get '/login'

    expect(admin_script_tags.size).to eq(1)
    expect(admin_script_tags.first['defer']).to eq('defer')
  end

  it 'is deferred on a page for a signed-in admin' do
    sign_in admin_user
    get '/dashboard'

    expect(admin_script_tags.size).to eq(1)
    expect(admin_script_tags.first['defer']).to eq('defer')
  end
end

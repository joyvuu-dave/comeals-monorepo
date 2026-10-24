# frozen_string_literal: true

require 'rails_helper'

# The admin login page says which login it is and points residents at
# theirs. active_admin.js used to add that banner with jQuery once the
# page was ready, so it moved the form down after the first paint (a
# layout shift) and was the page's largest paint, held back by the
# script. The server writes it now, in the copy of ActiveAdmin's
# logged-out layout (app/views/layouts/active_admin_logged_out.html.erb).
RSpec.describe 'The admin login banner' do
  before { host! 'admin.example.com' }

  def banner
    response.parsed_body.at_css('body > .admin-login-banner')
  end

  it 'is in the page the server sends, first in the body' do
    get '/login'

    expect(banner).to be_present
    expect(banner.at_css('h3').text).to eq('Admin Login')
    link = banner.at_css('a')
    expect(link.text).to eq('Looking for the resident login?')
    # The resident app is on the same host without the admin subdomain.
    expect(link['href']).to eq('http://example.com')
    first = response.parsed_body.at_css('body').element_children.first
    expect(first['class']).to eq('admin-login-banner')
  end

  it 'keeps the port of the address the page was asked on' do
    host! 'admin.lvh.me:3000'
    get '/login'

    expect(banner.at_css('a')['href']).to eq('http://lvh.me:3000')
  end

  # The other logged-out pages (forgot password, reset password) never
  # had it.
  it 'is not on the forgot-password page' do
    get '/password/new'

    expect(response).to have_http_status(:ok)
    expect(banner).to be_nil
  end

  it 'is no longer added by the admin script' do
    script = Rails.root.join('app/assets/javascripts/active_admin.js').read

    expect(script).not_to include('admin-login-banner')
  end
end

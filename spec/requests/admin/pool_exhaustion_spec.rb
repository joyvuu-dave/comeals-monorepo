# frozen_string_literal: true

require 'rails_helper'

# The admin half of spec/requests/api/v1/pool_exhaustion_spec.rb: the same
# 503, rendered as plain text with no layout, because an ActiveAdmin
# layout reads the database to draw itself and there is no connection to
# be had.
RSpec.describe 'an admin request that cannot get a database connection' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  it 'answers 503 with a Retry-After, not 500' do
    allow(Resident).to receive(:ransack).and_raise(
      ActiveRecord::ConnectionTimeoutError,
      'could not obtain a connection from the pool within 5.000 seconds'
    )

    get '/residents'

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Retry-After']).to eq('5')
    expect(response.body).to include('The server is busy right now')
  end
end

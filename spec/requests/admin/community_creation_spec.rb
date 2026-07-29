# frozen_string_literal: true

require 'rails_helper'

# The communities table holds exactly one row. Creating it is a bootstrap step
# on an empty database (spec/requests/admin/bootstrap_guard_spec.rb covers
# that path). Once the row exists there is nothing left to create, so
# SuperuserAdapter refuses both `new` and `create` — the "New Community"
# button is gone from the index and the URLs are denied.
RSpec.describe 'Admin community creation' do
  let!(:community) { create(:community) }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  def expect_denied
    expect(response).to redirect_to('http://admin.example.com/')
    expect(flash[:error]).to eq('You are not authorized to perform this action.')
  end

  it 'does not show a New Community button on the index' do
    get '/communities'

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('/communities/new')
  end

  it 'denies GET /communities/new' do
    get '/communities/new'

    expect_denied
  end

  it 'denies POST /communities' do
    expect do
      post '/communities', params: {
        community: {
          name: 'Second Community',
          slug: 'second',
          cap: '2.50',
          timezone: 'America/New_York'
        }
      }
    end.not_to change(Community, :count)

    expect_denied
  end

  it 'still allows editing the one community that exists' do
    patch "/communities/#{community.id}", params: { community: { name: 'Renamed' } }

    expect(community.reload.name).to eq('Renamed')
  end
end

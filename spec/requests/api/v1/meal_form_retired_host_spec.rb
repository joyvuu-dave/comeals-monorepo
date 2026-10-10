# frozen_string_literal: true

require 'rails_helper'

# A resident can add a guest to a meal without signing up, and can then
# be retired. The meal page shows a guest only in its host's row, and
# builds its rows from the meal form's residents list. Before #134 that
# list left out a retired host who did not eat. So the guest was counted
# and charged to the host, but no row showed it, and nobody could remove
# it from the page. This spec reads the form, removes the guest the way
# the page does, and reads the form again.
RSpec.describe 'A host retired after adding a guest to an open meal' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:host) { create(:resident, community: community, unit: unit) }
  let(:token) { host.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  def meal_form
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  it 'is in the meal form while the guest is on the meal, and not after the guest is removed' do
    post "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests", params: { token: token, vegetarian: false },
                                                                 headers: IdempotencyKey.header
    expect(response).to have_http_status(:ok)
    guest_id = response.parsed_body['id']
    host.update!(active: false)

    form = meal_form
    expect(form['guests'].pluck('id', 'resident_id')).to eq([[guest_id, host.id]])
    expect(form['residents'].find { |row| row['id'] == host.id })
      .to include('active' => false, 'attending' => false)

    delete "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests/#{guest_id}", params: { token: token }
    expect(response).to have_http_status(:ok)

    form = meal_form
    expect(form['guests']).to eq([])
    expect(form['residents'].pluck('id')).not_to include(host.id)
  end
end

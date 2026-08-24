# frozen_string_literal: true

require 'rails_helper'

# The attendance endpoints check that the resident in the URL exists before
# touching the meal, so a stale client (a resident retired and deleted while
# a page was open) gets a readable 400, not a foreign-key 500.
RSpec.describe 'meal attendance for a resident who does not exist' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  it 'refuses to add them' do
    expect do
      post "/api/v1/meals/#{meal.id}/residents/999999", params: { token: token, late: false, vegetarian: false }
    end.not_to change(MealResident, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['message']).to eq('Resident not found.')
  end

  it 'refuses to add a guest for them' do
    expect do
      post "/api/v1/meals/#{meal.id}/residents/999999/guests", params: { token: token, multiplier: 2 }
    end.not_to change(Guest, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['message']).to eq('Resident not found.')
  end
end

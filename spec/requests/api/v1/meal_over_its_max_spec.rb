# frozen_string_literal: true

require 'rails_helper'

# A closed meal can have more eaters than its max without any hand edit:
# an admin attendance correction (app/admin/meal_resident.rb) skips the
# open-spots check, so it can add a person to a full closed meal. The
# cook's own writes on that meal do not touch max, so the stale max must
# not refuse them.
RSpec.describe 'A closed meal with more eaters than its max' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.tomorrow) }

  before do
    create(:meal_resident, meal: meal, resident: resident, community: community)
    meal.update!(closed: true, max: 1)
    late_eater = create(:resident, community: community, unit: unit)
    create(:meal_resident, meal: meal, resident: late_eater, community: community, admin_correction: true)
  end

  # The reopen clears max before the max check reads it.
  it 'reopens, and the reopen clears max' do
    patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: false }

    expect(response.parsed_body['message']).to eq('Meal closed value updated.')
    expect(response).to have_http_status(:ok)
    expect(meal.reload).to have_attributes(closed: false, max: nil)
  end

  # The max check runs only when max changes.
  it 'takes a new description' do
    patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Soup' }

    expect(response.parsed_body['message']).to eq('Description updated.')
    expect(response).to have_http_status(:ok)
    expect(meal.reload.description).to eq('Soup')
  end

  it 'takes a max that makes room for every eater' do
    patch "/api/v1/meals/#{meal.id}/max", params: { token: token, max: 2 }

    expect(response.parsed_body['message']).to eq('Meal max value updated.')
    expect(response).to have_http_status(:ok)
    expect(meal.reload.max).to eq(2)
  end
end

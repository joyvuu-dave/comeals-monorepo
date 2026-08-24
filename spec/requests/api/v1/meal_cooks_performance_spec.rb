# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meal show_cooks endpoint performance' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  before do
    # Create a bill and some attendees to exercise the serializer
    create(:bill, meal: meal, resident: resident, community: community)
    5.times do
      r = create(:resident, community: community, unit: unit)
      create(:meal_resident, meal: meal, resident: r, community: community)
    end
  end

  # Nothing on this page is cached (MealsController#show_cooks says why),
  # so this bound holds for every request, not only the first. The budget:
  # token auth (2), the meal with its bills, attendance and guests (4), the
  # sign-up list with units (2), and the previous and next meal ids (2).
  it 'loads the meal form in a bounded number of queries on every request' do
    token # force memoization before the counted block so lazy .keys load doesn't pollute
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }

    query_count = count_queries do
      get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    end

    expect(response).to have_http_status(:ok)
    expect(query_count).to be <= 11
  end
end

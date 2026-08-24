# frozen_string_literal: true

require 'rails_helper'

# Settling a meal changes what its cooks page says (`reconciled`), and that
# page is served from the meal-<id> cache. The claim is an update_all that
# fires no callbacks, so the settlement itself has to clear the cache
# (issue #70). Without that, a page cached before the settlement keeps
# saying the meal is open.
RSpec.describe 'the cooks page after a settlement' do # -- a request contract across the API and Settlement
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  # The test environment uses a null cache store, which would hide the bug.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  it 'stops saying the meal is open the moment it is settled' do
    meal = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))

    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    expect(response.parsed_body[:reconciled]).to be(false)

    settle!(community)

    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    expect(response.parsed_body[:reconciled]).to be(true)
  end
end

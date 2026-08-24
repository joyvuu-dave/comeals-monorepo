# frozen_string_literal: true

require 'rails_helper'

# The cooks page (GET /api/v1/meals/:id/cooks) holds more than the meal:
# every resident in the sign-up list (name, unit, active, can_cook) and the
# ids of the meals before and after this one. It used to be served from a
# meal-<id> cache that was cleared only when THIS meal was written or
# settled, so a retired resident, an old name, or a dead "next" arrow stayed
# on screen for up to a day (#76). The page is built fresh now; this spec
# keeps it that way.
RSpec.describe 'the cooks page after a change outside the meal' do # -- a request contract across the API and the models
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.tomorrow) }

  # The test environment uses a null cache store, which would hide a cache
  # that lies. A real store here proves nothing on this path is cached.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  def cooks_page
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    response.parsed_body
  end

  def row_for(resident)
    cooks_page[:residents].find { |row| row[:id] == resident.id }
  end

  it 'drops a resident from the sign-up list once they are retired' do
    other = create(:resident, community: community, unit: unit, name: 'Pat')
    expect(row_for(other)[:active]).to be(true)

    other.update!(active: false)

    expect(row_for(other)).to be_nil
  end

  it 'shows a resident under their new name' do
    other = create(:resident, community: community, unit: unit, name: 'Pat')
    expect(row_for(other)[:name]).to eq("#{unit.name} - Pat")

    other.update!(name: 'Patricia')

    expect(row_for(other)[:name]).to eq("#{unit.name} - Patricia")
  end

  it 'points next_id at a meal created after the page was cached' do
    expect(cooks_page[:next_id]).to eq(meal.id)

    later = create(:meal, community: community, date: Date.tomorrow + 1)

    expect(cooks_page[:next_id]).to eq(later.id)
  end
end

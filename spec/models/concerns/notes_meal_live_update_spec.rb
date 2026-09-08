# frozen_string_literal: true

require 'rails_helper'

# A bill, an attendance row, or a guest moved from one meal to another
# changes two meal pages and up to two calendar months. Both must be told.
RSpec.describe NotesMealLiveUpdate do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:from) { create(:meal, community: community, date: Date.new(2026, 3, 30)) }
  let(:to) { create(:meal, community: community, date: Date.new(2026, 5, 4)) }

  it 'tells the old meal and the old month as well as the new ones when a bill moves' do
    bill = create(:bill, meal: from, resident: cook, community: community, amount: BigDecimal('10'))
    to # created here, because a new meal also tells its neighbors' pages (Meal#note_live_update)
    channels = []
    allow(Pusher).to receive(:trigger) { |channel, *| channels << channel }

    bill.update!(meal: to)

    expect(channels).to include("meal-#{from.id}", "meal-#{to.id}",
                                community.calendar_cache_key(2026, 3), community.calendar_cache_key(2026, 5))
    expect(channels.uniq).to eq(channels)
  end
end

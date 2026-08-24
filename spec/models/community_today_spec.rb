# frozen_string_literal: true

require 'rails_helper'

# "Today" on the settlement path is the community's day, not the app's.
# config.time_zone is America/Los_Angeles, and the rake tasks run in it;
# API requests run in the community's zone. A community elsewhere would
# otherwise have its dinners swept while people were still eating: at
# 10 pm in Hawaii it is already tomorrow in Los Angeles.
RSpec.describe 'the community day' do # rubocop:disable RSpec/DescribeClass -- a rule across Community, Meal and Settlement
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community, timezone: 'Pacific/Honolulu') }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }

  # 2026-08-24 07:30 UTC = 2026-08-24 00:30 in Los Angeles = 2026-08-23 21:30 in Honolulu.
  it 'is the community day, not the app time zone day' do
    travel_to(Time.utc(2026, 8, 24, 7, 30)) do
      expect(Time.zone.today).to eq(Date.new(2026, 8, 24)) # Los Angeles
      expect(community.today).to eq(Date.new(2026, 8, 23)) # Honolulu, dinner still on the table
      expect(community.yesterday).to eq(Date.new(2026, 8, 22))
    end
  end

  it 'does not let a settlement sweep a dinner that is still on the table in the community' do
    travel_to(Time.utc(2026, 8, 24, 7, 30)) do
      tonight = create(:meal, community: community, date: Date.new(2026, 8, 23))
      create(:bill, meal: tonight, resident: cook, community: community, amount: BigDecimal('30'))
      finished = create(:meal, community: community, date: Date.new(2026, 8, 22))
      create(:bill, meal: finished, resident: cook, community: community, amount: BigDecimal('30'))

      expect(Meal.settleable_by(Date.new(2026, 8, 23))).to contain_exactly(finished)

      reconciliation = build(:reconciliation, community: community, end_date: Date.new(2026, 8, 23))
      expect(reconciliation).not_to be_valid
      expect(reconciliation.errors[:end_date]).to include('must be in the past')

      expect(Settlement.run!(cutoff: community.yesterday, community: community).meals).to contain_exactly(finished)
      expect(tonight.reload.reconciliation_id).to be_nil
    end
  end
end

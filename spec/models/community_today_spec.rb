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
      # Tonight has a bill and an eater, like the finished meal, so the
      # only thing that can leave it out is that its day is not over yet
      # in Honolulu. A meal with a bill and nobody who ate is held back
      # on any date, so it could not show that.
      tonight = create(:meal, community: community, date: Date.new(2026, 8, 23))
      create(:bill, meal: tonight, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: tonight, resident: cook, community: community)
      finished = create(:meal, community: community, date: Date.new(2026, 8, 22))
      create(:bill, meal: finished, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: finished, resident: cook, community: community)

      expect(Meal.settleable_by(Date.new(2026, 8, 23))).to contain_exactly(finished)

      # August 23 is already over in Los Angeles, but not in Honolulu.
      expect { Settlement.preview(cutoff: Date.new(2026, 8, 23)) }
        .to raise_error(Settlement::InvalidCutoff, 'cutoff must be in the past')
      expect { Settlement.run!(cutoff: Date.new(2026, 8, 23)) }
        .to raise_error(ActiveRecord::RecordInvalid, /End date must be in the past/)

      reconciliation = build(:reconciliation, community: community, end_date: Date.new(2026, 8, 23))
      expect(reconciliation).not_to be_valid
      expect(reconciliation.errors[:end_date]).to include('must be in the past')

      expect(Settlement.run!(cutoff: community.yesterday).meals).to contain_exactly(finished)
      expect(tonight.reload.reconciliation_id).to be_nil
    end
  end

  context 'when the community is east of the app time zone' do
    let(:community) { create(:community, timezone: 'America/New_York') }

    # 2026-08-24 04:30 UTC = 2026-08-24 00:30 in New York = 2026-08-23 21:30 in Los Angeles.
    it "settles last night's dinner as soon as the community's day is over" do
      travel_to(Time.utc(2026, 8, 24, 4, 30)) do
        last_night = create(:meal, community: community, date: Date.new(2026, 8, 23))
        create(:bill, meal: last_night, resident: cook, community: community, amount: BigDecimal('30'))
        create(:meal_resident, meal: last_night, resident: cook, community: community)

        expect(community.yesterday).to eq(Date.new(2026, 8, 23))
        expect(Meal.settleable_by(community.yesterday)).to contain_exactly(last_night)
        expect(Settlement.preview(cutoff: community.yesterday).meals).to contain_exactly(last_night)
        expect(Settlement.run!(cutoff: community.yesterday).meals).to contain_exactly(last_night)
      end
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The resident factory turns `multiplier: 0` and `multiplier: 1` into a
# birthday counted back from today, and the meal factory dates a meal up
# to DefaultMealDate.days_back days back. A price is read on the meal's
# date, so these two promises only hold together while the window is
# short enough. This spec checks them at both ends of the window, so a
# longer window or a younger factory child fails here, by name, and not
# as a wrong money number in some unrelated spec (#117).
RSpec.describe 'factory price bands' do # rubocop:disable RSpec/DescribeClass -- checks two factories together
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  it 'dates default meals from yesterday back to the end of the window, and then starts again' do
    days_back = DefaultMealDate.days_back

    expect(DefaultMealDate.for(1)).to eq(1.day.ago.to_date)
    expect(DefaultMealDate.for(days_back)).to eq(days_back.days.ago.to_date)
    expect(DefaultMealDate.for(days_back + 1)).to eq(1.day.ago.to_date)
  end

  [1, DefaultMealDate.days_back].each do |n|
    it "gives each factory price band its own price on a default meal #{n} days back" do
      meal = create(:meal, community: community, date: DefaultMealDate.for(n))

      prices = [Multiplier::FREE, Multiplier::HALF, Multiplier::FULL].to_h do |band|
        resident = create(:resident, community: community, unit: unit, multiplier: band)
        [band, create(:meal_resident, meal: meal, resident: resident, community: community).multiplier]
      end

      expect(prices).to eq(Multiplier::FREE => Multiplier::FREE,
                           Multiplier::HALF => Multiplier::HALF,
                           Multiplier::FULL => Multiplier::FULL)
    end
  end
end

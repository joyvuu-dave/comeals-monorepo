# frozen_string_literal: true

require 'rails_helper'

# "Every wall-clock time is read in the community's zone" (CLAUDE.md). Inside
# an API request that is true by ApiController#set_community_timezone, which
# wraps the call in Time.use_zone. Jobs, rake tasks, and admin have no such
# wrapper, so Time.zone there is the app's fixed default (Pacific). These
# examples run outside any request, with the community in New York, at an
# instant where the two zones are on different dates: 05:30 UTC on April 10
# is 22:30 on the 9th in Los Angeles and 01:30 on the 10th in New York.
RSpec.describe Community, '#today' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community, timezone: 'America/New_York') }
  let(:unit) { create(:unit, community: community) }

  before { travel_to(Time.utc(2026, 4, 10, 5, 30)) }

  it 'is the 10th for the community while the app zone still says the 9th (the premise)' do
    expect(Time.zone.today).to eq(Date.new(2026, 4, 9))
    expect(community.today).to eq(Date.new(2026, 4, 10))
  end

  it 'Rotation#touched_meals counts a meal dated today as already happened' do
    rotation = create(:rotation, community: community)
    meal = create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 10))

    expect(rotation.touched_meals).to include(meal)
  end

  it 'Resident#age turns a year older on the birthday, in the community zone' do
    resident = create(:resident, community: community, unit: unit, birthday: Date.new(2016, 4, 10), multiplier: 1)

    expect(resident.age).to eq(10)
  end

  it 'Community#create_next_rotation starts from the community day' do
    community.update!(schedule: [[0, 1, 2, 3, 4, 5, 6]], meals_per_rotation: 1)

    rotation = community.create_next_rotation

    expect(rotation.meals.first.date).to be >= Date.new(2026, 4, 10)
  end

  it 'MealSerializer says "attending" about a dinner on the community day' do
    meal = create(:meal, community: community, date: Date.new(2026, 4, 10))

    expect(MealSerializer.new(meal).to_h[:title]).to include('attending')
  end
end

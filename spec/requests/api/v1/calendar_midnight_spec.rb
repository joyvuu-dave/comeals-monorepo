# frozen_string_literal: true

require 'rails_helper'

# A meal's calendar chip says "signed up" before its day, "attending" on
# its day, and "attended" after (MealSerializer#title). That word depends
# on today's date, and the month is cached for an hour — so a month built
# at 23:30 still says "signed up" about today's dinner at 00:30. Nothing
# writes at midnight, so no write clears it. The cache version has to
# carry the day.
RSpec.describe 'the calendar at midnight' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  it 'stops saying "signed up" about a dinner once its day has come' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))

    travel_to Time.zone.local(2026, 4, 9, 23, 30) do
      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
      expect(response.body).to include('signed up')
    end

    travel_to Time.zone.local(2026, 4, 10, 0, 30) do
      get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
      expect(response.body).to include('attending')
      expect(response.body).not_to include('signed up')
    end
  end
end

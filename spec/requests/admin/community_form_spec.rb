# frozen_string_literal: true

require 'rails_helper'

# The community form is the only way to change the dinner start times and
# the time zone. Neither shows on the calendar grid (a meal is a date
# there); both show in the iCal feed, and the zone also decides what
# "today" is, which the calendar chips read ("signed up" / "attending").
# Checked through the API against a real cache.
RSpec.describe 'Admin community form: times and zone' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) do
    create(:community, dinner_start_times: %w[18:00 19:00 19:00 19:00 19:00 19:00 19:00])
  end
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:sunday_meal) { create(:meal, community: community, date: Date.new(2026, 4, 5)) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def submit(attributes)
    host! 'admin.example.com'
    sign_in admin_user
    patch "/communities/#{community.id}", params: { community: attributes }
    expect(response).to redirect_to("/communities/#{community.id}")
    host! 'www.example.com'
  end

  def ical
    get "/api/v1/residents/#{resident.id}/ical"
    response.body
  end

  def calendar
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    response.body
  end

  it 'a new dinner start time reaches the iCal feed' do
    create(:bill, meal: sunday_meal, resident: resident, community: community)
    expect(ical).to include('DTSTART;TZID=America/Los_Angeles:20260405T180000')

    submit(dinner_start_times: { '0' => '17:30', '1' => '19:00', '2' => '19:00', '3' => '19:00',
                                 '4' => '19:00', '5' => '19:00', '6' => '19:00' })

    expect(community.reload.dinner_start_times.first).to eq('17:30')
    expect(ical).to include('DTSTART;TZID=America/Los_Angeles:20260405T173000')
    expect(ical).not_to include('T180000')
  end

  it 'a new time zone keeps the wall-clock time and moves the zone in the iCal feed' do
    create(:bill, meal: sunday_meal, resident: resident, community: community)

    submit(timezone: 'America/New_York')

    expect(ical).to include('DTSTART;TZID=America/New_York:20260405T180000')
    expect(ical).not_to include('America/Los_Angeles')
  end

  it 'a new time zone changes what "today" is, and the cached calendar follows' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))

    # 05:30 UTC on April 10: still April 9 in Los Angeles, already April 10 in New York.
    travel_to Time.utc(2026, 4, 10, 5, 30) do
      expect(calendar).to include('signed up')

      submit(timezone: 'America/New_York')

      expect(calendar).to include('attending')
      expect(calendar).not_to include('signed up')
    end
  end

  it 'refuses a zone that is not on the list, and says so' do
    host! 'admin.example.com'
    sign_in admin_user
    patch "/communities/#{community.id}", params: { community: { timezone: 'Mars/Olympus' } }

    expect(community.reload.timezone).to eq('America/Los_Angeles')
    expect(response.body).to include('not included in the list')
  end
end

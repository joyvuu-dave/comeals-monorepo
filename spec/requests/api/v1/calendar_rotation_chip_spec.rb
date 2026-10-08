# frozen_string_literal: true

require 'rails_helper'

# A rotation's chip on the calendar runs from its first meal to its last
# (RotationSerializer), and a month shows it when one of the rotation's
# meals is in the month's six weeks. So a meal made, deleted or moved at
# either end of a rotation changes the chip on every month that shows
# the rotation, also a month whose six weeks do not hold the meal's date.
# Through the admin forms and the real API, against a real cache.
#
# January 2027's calendar is the six weeks from Sun 2026-12-27 to Sat
# 2027-02-06. The rotation has meals on 2027-01-20 and 2027-02-03, so
# January shows it. Every write below is on a date after 2027-02-06.
#
# Before the fix, January's cached month kept the old chip for up to an
# hour: its version counted only the meals dated inside its six weeks
# (#144; the admin New Meal form of #100 is the second way to get here).
RSpec.describe "Calendar: a rotation's chip on a month that does not hold the changed meal" do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:rotation) { create(:rotation, community: community) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  before do
    create(:meal, community: community, rotation: rotation, date: Date.new(2027, 1, 20))
    create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 3))
    # The admin forms refuse a date after the last meal of the calendar
    # (#143). So a later rotation has a meal after every date below. That
    # meal is outside January's six weeks, so January does not show its
    # rotation.
    create(:meal, community: community, rotation: create(:rotation, community: community),
                  date: Date.new(2027, 3, 20))
  end

  # The last day of the chip on January's calendar. The chip's end is the
  # last minute of the rotation's last meal day.
  def january_chip_end
    host! 'www.example.com'
    get "/api/v1/communities/#{community.id}/calendar/2027-01-15", params: { token: token }
    chip = response.parsed_body['rotations'].find { |r| r['url'] == "rotations/show/#{rotation.id}" }
    chip['end'].to_s[0, 10]
  end

  def as_admin
    host! 'admin.example.com'
    sign_in admin_user
    yield
  end

  it 'makes the chip longer when the admin adds a one-off meal after its last meal' do
    expect(january_chip_end).to eq('2027-02-03')

    as_admin do
      post '/meals', params: { meal: { date: '2027-02-08', closed: '0', rotation_id: rotation.id } }
    end
    expect(Meal.find_by!(date: Date.new(2027, 2, 8)).rotation).to eq(rotation)

    expect(january_chip_end).to eq('2027-02-08')
  end

  it 'makes the chip shorter when the admin deletes its last meal' do
    last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 8))
    expect(january_chip_end).to eq('2027-02-08')

    as_admin { delete "/meals/#{last.id}" }
    expect(Meal.exists?(last.id)).to be(false)

    expect(january_chip_end).to eq('2027-02-03')
  end

  it 'moves the end of the chip when the admin moves its last meal' do
    last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 8))
    expect(january_chip_end).to eq('2027-02-08')

    as_admin { patch "/meals/#{last.id}", params: { meal: { date: '2027-02-12' } } }
    expect(last.reload.date).to eq(Date.new(2027, 2, 12))

    expect(january_chip_end).to eq('2027-02-12')
  end
end

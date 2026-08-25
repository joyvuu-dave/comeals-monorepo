# frozen_string_literal: true

require 'rails_helper'

# The admin resident form is the only way to rename, retire, re-price, or
# move a resident. Each change is checked the way a resident would see it:
# through the cooks page and the calendar, against a real cache (#77 was a
# rename that a cache hid), and against the settled ledger, which must not
# move when the resident does.
RSpec.describe 'Admin resident form' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'A1') }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:viewer) { create(:resident, community: community, unit: unit, name: 'Viewer') }
  let(:token) { viewer.keys.first.token }
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Pat', multiplier: 2) }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def submit(attributes)
    host! 'admin.example.com'
    sign_in admin_user
    patch "/residents/#{resident.id}", params: { resident: attributes }
    expect(response).to redirect_to("/residents/#{resident.id}")
    host! 'www.example.com'
  end

  def cooks_row
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    response.parsed_body[:residents].find { |row| row[:id] == resident.id }
  end

  def calendar_body
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    response.body
  end

  it 'rename: the cooks page and the calendar show the new name' do
    create(:bill, meal: meal, resident: resident, amount: 10)
    expect(cooks_row[:name]).to eq('A1 - Pat')
    expect(calendar_body).to include('Pat')

    submit(name: 'Patricia')

    expect(cooks_row[:name]).to eq('A1 - Patricia')
    expect(calendar_body).to include('Patricia')
    expect(calendar_body).not_to match(/Pat\b/)
  end

  it 'retire: the resident leaves the sign-up list' do
    resident
    expect(cooks_row).to be_present

    submit(active: '0')

    expect(resident.reload.active).to be(false)
    expect(cooks_row).to be_nil
  end

  it 'move to another unit: the cooks page shows the new unit' do
    other_unit = create(:unit, community: community, name: 'B2')

    submit(unit_id: other_unit.id)

    expect(cooks_row[:name]).to eq('B2 - Pat')
  end

  it 'change the price category by hand: attendance already recorded keeps its own snapshot' do
    open_meal = create(:meal, community: community, date: Date.new(2026, 5, 10))
    open_row = create(:meal_resident, meal: open_meal, resident: resident, community: community, multiplier: 2)

    create(:bill, meal: meal, resident: viewer, community: community, amount: 10)
    settled_row = create(:meal_resident, meal: meal, resident: resident, community: community, multiplier: 2)
    create(:reconciliation, community: community)
    raise 'setup failed: meal was not settled' unless meal.reload.reconciled?

    # A half-price resident is a child, and a child must have a birthday.
    submit(multiplier: 1, birthday: 8.years.ago.to_date.iso8601)

    expect(resident.reload.multiplier).to eq(1)
    expect(open_row.reload.multiplier).to eq(2)
    expect(settled_row.reload.multiplier).to eq(2)
  end
end

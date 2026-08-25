# frozen_string_literal: true

require 'rails_helper'

# Renaming a unit through the admin form. The unit's name is part of every
# resident's label on the cooks page and of the cook's name on the calendar,
# both served through a cache, so the check is made through the API against
# a real cache (as #77 taught).
RSpec.describe 'Admin unit form' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Old Unit') }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Pat') }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def cooks_row_name
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    response.parsed_body[:residents].find { |row| row[:id] == resident.id }[:name]
  end

  def calendar_body
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    response.body
  end

  it 'shows the new name on the cooks page and the calendar' do
    create(:bill, meal: meal, resident: resident, amount: 10)
    expect(cooks_row_name).to eq('Old Unit - Pat')
    expect(calendar_body).to include('Old Unit')

    host! 'admin.example.com'
    sign_in admin_user
    patch "/units/#{unit.id}", params: { unit: { name: 'New Unit' } }
    expect(response).to redirect_to("/units/#{unit.id}")
    host! 'www.example.com'

    expect(cooks_row_name).to eq('New Unit - Pat')
    expect(calendar_body).to include('New Unit')
    expect(calendar_body).not_to include('Old Unit')
  end
end

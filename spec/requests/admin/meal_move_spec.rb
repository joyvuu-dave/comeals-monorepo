# frozen_string_literal: true

require 'rails_helper'

# The admin meal form is the only way to move a meal to another date. The
# calendar month is cached, so the check is: after the form saves, the old
# month no longer lists the meal and the new month does. Through the real
# API and a real cache, not the model.
RSpec.describe 'Admin meal form: moving a meal to another date' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def meal_dates_in(month)
    get "/api/v1/communities/#{community.id}/calendar/#{month}", params: { token: token }
    response.parsed_body['meals'].map { |m| m['start'].to_s[0, 10] }
  end

  it 'takes the meal out of the old month and puts it in the new one' do
    meal
    expect(meal_dates_in('2026-04-15')).to include('2026-04-10')
    expect(meal_dates_in('2026-06-15')).not_to include('2026-06-10')

    host! 'admin.example.com'
    sign_in admin_user
    patch "/meals/#{meal.id}", params: { meal: { date: '2026-06-10' } }
    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload.date).to eq(Date.new(2026, 6, 10))

    host! 'www.example.com'
    expect(meal_dates_in('2026-04-15')).not_to include('2026-04-10')
    expect(meal_dates_in('2026-06-15')).to include('2026-06-10')
  end

  it 'refuses to move a reconciled meal' do
    reconciliation = create(:reconciliation, community: community)
    meal.update_columns(reconciliation_id: reconciliation.id)

    host! 'admin.example.com'
    sign_in admin_user
    patch "/meals/#{meal.id}", params: { meal: { date: '2026-06-10' } }

    expect(meal.reload.date).to eq(Date.new(2026, 4, 10))
    expect(flash[:alert]).to include('reconciled')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# What the Common House screen may do once it is signed in
# (ApiController#current_login). It may do everything a signed-in resident
# may, except the two things that need a person: settle a period, and read
# "which resident am I".
RSpec.describe 'A Common House session' do
  let!(:community) { create(:community, timezone: 'America/New_York') }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:login) { create(:common_house_login) }
  let(:headers) { { 'Authorization' => "Bearer #{JwtAuth.encode(login)}" } }

  it 'may sign a resident up for dinner' do
    meal = create(:meal, community: community)

    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
         params: { late: false, vegetarian: false }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(meal.meal_residents.where(resident: resident).count).to eq(1)
  end

  it 'names the Common House login, not a resident, as the author in the history' do
    meal = create(:meal, community: community)

    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
         params: { late: false, vegetarian: false }, headers: headers

    audit = MealResident.find_by!(meal: meal, resident: resident).audits.sole
    expect(audit).to have_attributes(user_type: 'CommonHouseLogin', user_id: login.id)
  end

  # The history of the dinner is a page every resident reads. A row the
  # screen wrote must show, with its name, and not break the page.
  it 'shows its sign-up in the dinner history as the Common House' do
    meal = create(:meal, community: community)
    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
         params: { late: false, vegetarian: false }, headers: headers

    get "/api/v1/meals/#{meal.id}/history", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['items'].pluck('user_name')).to include('Common House')
  end

  # 19:00 typed at the screen is 19:00 in New York, the community's zone,
  # not in the app's default zone.
  it "reads the times it sends in the community's zone" do
    post '/api/v1/events', params: {
      title: 'Movie Night', all_day: false,
      start_year: 2026, start_month: 4, start_day: 15,
      start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 0
    }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Event.last.start_date).to eq(ActiveSupport::TimeZone['America/New_York'].local(2026, 4, 15, 19, 0))
  end

  it 'may sign out' do
    delete '/api/v1/sessions/current', headers: headers

    expect(response).to have_http_status(:ok)
  end

  # Reading a resident id answers 403: residents_controller_spec.rb.

  it 'may not preview a settlement, and is told why' do
    get '/api/v1/reconciliations/preview', params: { cutoff: 20.days.ago.to_date.iso8601 }, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq('message' => 'Only a resident may do this, not the Common House screen.')
  end

  it 'may not settle' do
    post '/api/v1/reconciliations', params: { cutoff: 20.days.ago.to_date.iso8601 }, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(Reconciliation.count).to eq(0)
  end
end

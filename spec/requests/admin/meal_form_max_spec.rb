# frozen_string_literal: true

require 'rails_helper'

# The admin meal form shows max for a closed meal and sends it back on
# every save. A closed meal can hold more eaters than its max: the admin
# attendance page adds a person past the open spots (admin_correction).
# The cook's side of the same state is in
# spec/requests/api/v1/meal_over_its_max_spec.rb.
RSpec.describe 'Admin meal form: max' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:meal) { create(:meal, community: community) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
    meal.update!(closed: true, max: 1)
  end

  def add_past_max
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community, admin_correction: true)
  end

  it 'reopens a meal with more eaters than its max, and clears max' do
    add_past_max

    patch "/meals/#{meal.id}", params: { meal: { closed: '0', max: '1' } }

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload).to have_attributes(closed: false, max: nil)
  end

  it 'saves a new date on a meal with more eaters than its max' do
    add_past_max
    new_date = meal.date + 1

    patch "/meals/#{meal.id}", params: { meal: { date: new_date.iso8601, max: '1' } }

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload).to have_attributes(date: new_date, max: 1)
  end

  it 'refuses a max below the headcount, and names max once' do
    patch "/meals/#{meal.id}", params: { meal: { max: '0' } }

    expect(response.body).to include('Max can&#39;t be less than current number of attendees.')
    expect(response.body).not_to include('Max Max')
    expect(meal.reload.max).to eq(1)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The dashboard's "Averages" panel, as an admin reads it. The nightly job
# keeps six months of upcoming meals, and they are unreconciled too, so
# the averages must leave them out or they sink toward zero (#98).
RSpec.describe 'Admin dashboard averages' do
  let(:community) { create(:community, cap: nil) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  it 'shows the cost per adult and attendees per meal of the meals up to today, rounded half up' do
    cook = create(:resident, community: community, unit: unit)
    diner = create(:resident, community: community, unit: unit)
    past = create(:meal, community: community, date: community.today - 1)
    create(:bill, meal: past, resident: cook, community: community, amount: BigDecimal('16.25'))
    create(:meal_resident, meal: past, resident: cook, community: community)
    create(:meal_resident, meal: past, resident: diner, community: community)
    upcoming = create(:meal, community: community, date: community.today + 7)
    create(:meal_resident, meal: upcoming, resident: diner, community: community)
    create(:meal, community: community, date: community.today + 14)

    get '/'

    # 2 * (16.25 / 4) is exactly 8.125; two people ate at the one past meal.
    expect(response.body).to include('Cost per adult: $8.13/adult')
    expect(response.body).to include('Attendees per meal: 2.0')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# A child younger than the community's free_below_age eats free
# (Multiplier::FREE). The admin pages that name a price category must say
# so, not "Adult x 0" (#99).
RSpec.describe 'Admin: a child who eats free' do
  let(:community) { create(:community, free_below_age: 5, full_price_age: 12) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:toddler) { create(:resident, community: community, unit: unit, birthday: community.today - 3.years) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  it 'is labeled free on the residents list and on the resident page' do
    toddler

    get '/residents'
    expect(response.body).to include('Child (free)')
    expect(response.body).not_to include('Adult x 0')

    get "/residents/#{toddler.id}"
    expect(response.body).to include('Child (free)')
    expect(response.body).not_to include('Adult x 0')
  end

  it "is labeled free on a settled meal's line items" do
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community, date: community.today - 1)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: toddler, community: community)
    settle!(cutoff: community.today - 1)

    get "/meals/#{meal.id}"

    expect(response.body).to include('Child (free)')
    expect(response.body).not_to include('Adult x 0')
  end
end

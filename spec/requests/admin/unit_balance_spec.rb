# frozen_string_literal: true

require 'rails_helper'

# The admin unit pages and the admin residents list show the same cached
# balances (resident_balances), so they must agree. Until #97 the unit
# pages showed $0.00 whenever no meal was open, while the residents list
# showed each resident's cached balance.
RSpec.describe 'Admin unit balance' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Unit 4') }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:owed) { create(:resident, community: community, unit: unit, name: 'Owed Person') }
  let(:owing) { create(:resident, community: community, unit: unit, name: 'Owing Person') }

  before do
    host! 'admin.example.com'
    sign_in admin_user
    ResidentBalance.create!(resident: owed, amount: BigDecimal('50'))
    ResidentBalance.create!(resident: owing, amount: BigDecimal('-12.25'))
  end

  it 'shows the sum of the residents on the unit page and the units list, with no meal open' do
    expect(Meal.unreconciled).to be_empty

    get "/units/#{unit.id}"
    expect(response.body).to include('is owed $37.75')

    get '/units'
    expect(response.body).to include('is owed $37.75')
  end

  it 'shows each resident on the residents list with the balance that the unit sums' do
    get '/residents'

    expect(response.body).to include('is owed $50.00')
    expect(response.body).to include('owes $12.25')
  end
end

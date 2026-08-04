# frozen_string_literal: true

require 'rails_helper'

# The resident index sorts by balance. The balance lives in the joined
# resident_balances table (see scoped_collection in app/admin/resident.rb),
# so this pins that the join is present and ORDER BY reaches it.
RSpec.describe 'Admin resident index balance sort' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  def body_position(response, name)
    position = response.body.index(name)
    expect(position).not_to be_nil, "expected the page to list #{name}"
    position
  end

  # Three residents whose balance order differs from their name order in both
  # directions, so neither assertion can pass by falling back to the default
  # name sort.
  it 'orders residents by their signed balance, most owed first on descending' do
    even = create(:resident, community: community, unit: unit, name: 'Alice Even')
    owed = create(:resident, community: community, unit: unit, name: 'Olive Owed')
    owing = create(:resident, community: community, unit: unit, name: 'Oscar Owing')
    ResidentBalance.create!(resident: even, amount: BigDecimal('0'))
    ResidentBalance.create!(resident: owed, amount: BigDecimal('10'))
    ResidentBalance.create!(resident: owing, amount: BigDecimal('-5'))

    get '/residents', params: { order: 'resident_balances.amount_desc' }

    expect(response).to have_http_status(:ok)
    expect(body_position(response, 'Olive Owed')).to be < body_position(response, 'Alice Even')
    expect(body_position(response, 'Alice Even')).to be < body_position(response, 'Oscar Owing')

    get '/residents', params: { order: 'resident_balances.amount_asc' }

    expect(body_position(response, 'Oscar Owing')).to be < body_position(response, 'Alice Even')
    expect(body_position(response, 'Alice Even')).to be < body_position(response, 'Olive Owed')
  end

  it 'still lists a resident who has no balance row yet' do
    create(:resident, community: community, unit: unit, name: 'Nina New')

    get '/residents', params: { order: 'resident_balances.amount_asc' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Nina New')
  end
end

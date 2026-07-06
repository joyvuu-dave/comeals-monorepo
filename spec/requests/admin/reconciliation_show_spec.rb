# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin Reconciliation Show' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:token) { 'test-readonly-token' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
  end

  it 'renders the show page with unit balances panel' do
    unit = create(:unit, community: community, name: 'Elm')
    resident = create(:resident, community: community, unit: unit)

    reconciliation = create(:reconciliation, community: community)
    create(:reconciliation_balance,
           reconciliation: reconciliation,
           resident: resident,
           amount: BigDecimal('42.50'))

    get "/reconciliations/#{reconciliation.id}",
        params: { token: token },
        headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Unit Balances')
    expect(response.body).to include('Elm')
    expect(response.body).to include('$42.50')
  end

  it 'renders the settled meals as a read-only list with no mutation form' do
    # Reconciliations are append-only settlement events (issue #4): the show
    # page must present the swept meals as a record, not offer checkboxes that
    # rewrite a settlement whose cooks were already emailed their amounts.
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit, name: 'Casey Cook', multiplier: 2)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))
    expect(meal.reload.reconciliation_id).to eq(reconciliation.id)

    get "/reconciliations/#{reconciliation.id}",
        params: { token: token },
        headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)

    # The swept meal is listed with its date, cooks, and cost…
    expect(response.body).to include('2025-03-01')
    expect(response.body).to include('Casey Cook')
    expect(response.body).to include('$40.00')

    # …but nothing on the page can rewrite the settlement.
    expect(response.body).not_to include('update_meals')
    expect(response.body).not_to include(%(name="meal_ids[]"))
    expect(response.body).not_to include('Update Meals')
  end
end

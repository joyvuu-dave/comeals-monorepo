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

  # Built from a real settlement: a hand-made balance row with nothing on
  # the other side is a state the deferred sum-to-zero trigger refuses at
  # commit. Two residents share a unit, so its row has to be their sum.
  it 'renders the show page with unit balances panel' do
    elm = create(:unit, community: community, name: 'Elm')
    oak = create(:unit, community: community, name: 'Oak')
    cook = create(:resident, community: community, unit: elm, name: 'Casey Cook', multiplier: 2)
    elm_eater = create(:resident, community: community, unit: elm, name: 'Dana Diner', multiplier: 2)
    oak_eater = create(:resident, community: community, unit: oak, name: 'Eli Eater', multiplier: 2)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: elm_eater, community: community)
    create(:meal_resident, meal: meal, resident: oak_eater, community: community)
    reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

    get "/reconciliations/#{reconciliation.id}",
        params: { token: token },
        headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    # Balances read as direction words, never signed numbers
    # (BalanceDisplayHelper).
    expect(panel_rows('Settlement Balances')).to eq([['Casey Cook', 'Elm', 'is owed $30.00'],
                                                     ['Dana Diner', 'Elm', 'owes $15.00'],
                                                     ['Eli Eater', 'Oak', 'owes $15.00']])
    expect(panel_rows('Unit Balances')).to eq([['Elm', 'is owed $15.00'], ['Oak', 'owes $15.00']])
    # The split totals under each table, and the zero-sum check.
    expect(panel_totals('Settlement Balances'))
      .to eq(['Owed to residents: $30.00', 'Owed by residents: $30.00', 'Difference: $0.00 ✓'])
    expect(panel_totals('Unit Balances'))
      .to eq(['Owed to units: $15.00', 'Owed by units: $15.00', 'Difference: $0.00 ✓'])
  end

  def panel(title)
    response.parsed_body.css('.panel').find { |node| node.at_css('h3')&.text&.strip == title }
  end

  def panel_rows(title)
    panel(title).css('tbody tr').map { |tr| tr.css('td').map { |td| td.text.strip } }
  end

  def panel_totals(title)
    panel(title).css('.settlement-total div').map { |div| div.text.strip }
  end

  it 'renders the settled meals as a read-only list with no mutation form' do
    # Reconciliations are append-only settlement events (issue #4): the show
    # page must present the swept meals as a record, not offer checkboxes that
    # rewrite a settlement whose cooks were already emailed their amounts.
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit, name: 'Casey Cook', multiplier: 2)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
    create(:meal_resident, meal: meal, resident: cook, community: community)

    reconciliation = settle!(cutoff: Date.new(2025, 3, 31))
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

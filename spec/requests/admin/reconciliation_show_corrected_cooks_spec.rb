# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 6: after a correction, "the old settlement's page still
# shows the dinner as it was settled". The Meals panel of a settlement's
# page has a Cooks column and a Total Cost column. Total Cost comes from
# the stored line items, so it stays as settled. Cooks comes from the
# dinner's bills as they are now.
#
# Bug hunt 2026-10-16 (money) found the Cooks column reading the bills.
# A correction moved a $30 cost from the cook it was typed under (Casey)
# to the cook who really paid (Robin). The old settlement credited Casey
# $30, and its own balances panel says so, but its Meals panel named
# Robin. The column now reads the cooks each dinner had when the
# settlement settled it (Reconciliation#settled_cooks_by_meal), and shows
# none for a cancelled dinner, which nobody cooked (ADR 0011 rule 11).
RSpec.describe 'Admin Reconciliation Show, a dinner corrected later' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:token) { 'test-readonly-token' }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
  end

  def panel_rows(title)
    panel = response.parsed_body.css('.panel').find { |node| node.at_css('h3')&.text&.strip == title }
    panel.css('tbody tr').map do |tr|
      tr.css('td').reject { |td| td['class'].to_s.match?(/col-(change_)?mark/) }.map { |td| td.text.strip }
    end
  end

  it 'names the cooks the settlement settled, not the cooks a later correction put on the dinner' do
    unit = create(:unit, community: community, name: 'Elm')
    casey = create(:resident, community: community, unit: unit, name: 'Casey Cook')
    robin = create(:resident, community: community, unit: unit, name: 'Robin Cook')
    dana = create(:resident, community: community, unit: unit, name: 'Dana Diner')
    meal = create(:meal, community: community, date: latest - 5)
    create(:bill, meal: meal, resident: casey, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: dana, community: community)
    reconciliation = settle!(cutoff: latest - 5)
    MealCorrecting.save!(meal.reload, by: admin_user, reason: 'Robin paid for this dinner, not Casey') do |edits|
      edits.remove_cook(casey)
      edits.cost(robin, amount: BigDecimal('30'), no_cost: false)
    end

    get "/reconciliations/#{reconciliation.id}", params: { token: token }, headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    expect(panel_rows('Settlement Balances')).to eq([['Casey Cook', 'Elm', 'is owed $30.00'],
                                                     ['Dana Diner', 'Elm', 'owes $30.00']])
    expect(panel_rows('Meals')).to eq([[meal.date.to_s, 'Casey Cook', '$30.00']])
  end

  it 'shows no cook for a cancelled dinner, whoever had signed up to cook it' do
    unit = create(:unit, community: community, name: 'Elm')
    casey = create(:resident, community: community, unit: unit, name: 'Casey Cook')
    dana = create(:resident, community: community, unit: unit, name: 'Dana Diner')
    meal = create(:meal, community: community, date: latest - 5)
    create(:bill, meal: meal, resident: casey, community: community, amount: BigDecimal('0'))
    create(:meal_resident, meal: meal, resident: dana, community: community)
    meal.cancel!
    reconciliation = settle!(cutoff: latest - 5)

    get "/reconciliations/#{reconciliation.id}", params: { token: token }, headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    expect(panel_rows('Meals')).to eq([[meal.date.to_s, '—', '']])
  end

  # A dinner nobody ate has no stored lines, so its Total Cost comes from
  # its receipts. A later correction changes them, and the record keeps
  # each cook's cost before (#177). Two such dinners, so the page shows
  # it reads them without a query per dinner (prosopite).
  it 'shows the Total Cost each dinner nobody ate was settled at, not what a later correction made it' do
    unit = create(:unit, community: community, name: 'Elm')
    casey = create(:resident, community: community, unit: unit, name: 'Casey Cook')
    dana = create(:resident, community: community, unit: unit, name: 'Dana Diner')
    reconciliation = create(:reconciliation, community: community)
    dinners = [latest - 6, latest - 5].map do |date|
      create(:meal, community: community, date: date).tap do |meal|
        create(:bill, meal: meal, resident: casey, community: community, amount: BigDecimal('40'))
        # Swept before 2026-09-10, when a receipt nobody ate was still swept.
        meal.update_columns(reconciliation_id: reconciliation.id)
      end
    end
    dinners.each do |meal|
      MealCorrecting.save!(meal.reload, by: admin_user, reason: 'Typed $40 for $25, and Dana ate') do |edits|
        edits.cost(casey, amount: BigDecimal('25'), no_cost: false)
        edits.add_eater(dana)
      end
    end

    get "/reconciliations/#{reconciliation.id}", params: { token: token }, headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    # The factory's settlement sweeps a dinner of its own too.
    expect(panel_rows('Meals')).to include(*dinners.map { |meal| [meal.date.to_s, 'Casey Cook', '$40.00'] })
  end
end

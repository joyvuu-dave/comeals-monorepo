# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 6: after a correction, "the old settlement's page still
# shows the dinner as it was settled". The Meals panel of a settlement's
# page has a Cooks column and a Total Cost column. Total Cost comes from
# the stored line items, so it stays as settled. Cooks comes from the
# dinner's bills as they are now.
#
# Bug hunt 2026-10-16 (money). A correction moved a $30 cost from the cook
# it was typed under (Casey) to the cook who really paid (Robin). The old
# settlement credited Casey $30, and its own balances panel says so, but
# its Meals panel now names Robin as the cook. Reconciliation.settled_cooks
# already answers "who cooked this dinner, as the settlement settled it";
# the panel does not use it.
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
end

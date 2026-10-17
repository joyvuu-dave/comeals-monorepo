# frozen_string_literal: true

require 'rails_helper'

# The page the cook mail links to: one cook's dinners in one settlement,
# at the cost each had when the settlement settled it, and a link to the
# dinner when a correction changed it later (ADR 0011 rule 6, #177).
#
# The mail used to link to the bills page filtered by the settlement and
# the cook. That page lists the bills as they are now, so after a
# correction it showed the new cost, and it left out a dinner whose bill
# a correction removed.
RSpec.describe 'Admin Reconciliation cook page' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:token) { 'test-readonly-token' }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:unit) { create(:unit, community: community, name: 'Elm') }
  let(:casey) { create(:resident, community: community, unit: unit, name: 'Casey Cook') }
  let(:robin) { create(:resident, community: community, unit: unit, name: 'Robin Cook') }
  let(:dana) { create(:resident, community: community, unit: unit, name: 'Dana Diner') }
  # Three dinners Casey cooked. A correction later changes the first
  # one's cost, and another moves the second one's cost to Robin. The
  # third is never corrected. The settlement credited Casey $30 + $12 + $8.
  # They are made out of date order, so a list by id is not a list by
  # date. A fourth dinner Casey signed up to cook was cancelled: nobody
  # cooked it (ADR 0011 rule 11).
  let!(:dinners) do
    third = dinner(latest - 5, casey, '8')
    [dinner(latest - 7, casey, '30'), dinner(latest - 6, casey, '12'), third]
  end
  let!(:cancelled) do
    dinner(latest - 8, casey, '0').tap(&:cancel!)
  end
  let!(:settlement) { settle!(cutoff: latest - 5) }

  before do
    host! 'admin.example.com'
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
    correct(dinners[0], 'Typed $30 for $20') { |edits| edits.cost(casey, amount: BigDecimal('20'), no_cost: false) }
    correct(dinners[1], 'Robin paid, not Casey') do |edits|
      edits.remove_cook(casey)
      edits.cost(robin, amount: BigDecimal('12'), no_cost: false)
    end
  end

  def dinner(date, cook, amount)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount))
      create(:meal_resident, meal: meal, resident: dana, community: community)
    end
  end

  def correct(meal, reason, &)
    MealCorrecting.save!(meal.reload, by: admin_user, reason: reason, &)
  end

  def rows
    response.parsed_body.css('table tbody tr').map { |tr| tr.css('td').map { |td| td.text.strip } }
  end

  def links
    response.parsed_body.css('table tbody a').map { |a| [a.text.strip, a['href']] }
  end

  it 'shows each dinner the cook cooked at the cost the settlement settled, with the token from the mail' do
    get "/reconciliations/#{settlement.id}/cook", params: { resident_id: casey.id, token: token }

    expect(response).to have_http_status(:ok)
    expect(settlement.meals).to include(cancelled)
    expect(response.parsed_body.at_css('#page_title').text).to include('Casey Cook')
    expect(rows).to eq([[dinners[0].date.to_s, '$30.00', 'Corrected later'],
                        [dinners[1].date.to_s, '$12.00', 'Corrected later'],
                        [dinners[2].date.to_s, '$8.00', '']])
    expect(links).to eq([[dinners[0].date.to_s, "/meals/#{dinners[0].id}"],
                         ['Corrected later', "/meals/#{dinners[0].id}"],
                         [dinners[1].date.to_s, "/meals/#{dinners[1].id}"],
                         ['Corrected later', "/meals/#{dinners[1].id}"],
                         [dinners[2].date.to_s, "/meals/#{dinners[2].id}"]])
  end

  it 'leaves out a dinner a correction made someone a cook of after the settlement' do
    get "/reconciliations/#{settlement.id}/cook", params: { resident_id: robin.id, token: token }

    expect(response).to have_http_status(:ok)
    expect(rows).to eq([])
    expect(response.parsed_body.at_css('#main_content').text)
      .to include('Robin Cook cooked no dinner in this settlement.')
  end

  # The page is a GET and has no form. The token's writes are refused
  # in SuperuserAdapter whatever the page, and read_only_token_spec tries
  # each kind; here the one write next to this page, a new settlement.
  it 'writes nothing for the token: the page has no form, and a write next to it is refused' do
    get "/reconciliations/#{settlement.id}/cook", params: { resident_id: casey.id, token: token }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.css('#main_content form')).to be_empty

    expect do
      post "/reconciliations/#{settlement.id}/cook", params: { resident_id: casey.id, token: token }
    end.to raise_error(ActionController::RoutingError)
    expect do
      post '/reconciliations', params: { reconciliation: { end_date: latest }, token: token }
    end.not_to(change { [Reconciliation.count, Bill.count, MealCorrection.count] })
    expect(response).to redirect_to('http://admin.example.com/')
  end

  it 'sends a visitor with no token to the login page' do
    get "/reconciliations/#{settlement.id}/cook", params: { resident_id: casey.id }

    expect(response).to redirect_to('http://admin.example.com/login')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The meal form (GET /meals/:id/cooks) and the bills save (PATCH
# /meals/:id/bills) are used together. A bills save lists every cook, and
# the server removes the bill of any cook the list leaves out
# (BillsPayload#write_to). Before #91 the form left out a retired cook who
# did not eat, so the page dropped that bill, and the next save deleted
# it. This spec acts like the page before its fix: it sends only the bills
# whose cook is in the form's residents list.
RSpec.describe 'A cook retired after cooking an open meal' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:token) { create(:resident, community: community, unit: unit).keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }

  it 'keeps their bill when someone saves another cook\'s cost from the meal form' do
    carol = create(:resident, community: community, unit: unit)
    bob = create(:resident, community: community, unit: unit)
    create(:bill, meal: meal, resident: carol, community: community, amount: BigDecimal('40'))
    create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('0'))
    carol.update!(active: false)

    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    form = response.parsed_body
    # Send only the bills whose cook is in the residents list. The person
    # edits Bob's cost; the other rows are untouched.
    kept = form['bills'].pluck('resident_id') & form['residents'].pluck('id')
    rows = kept.map { |id| { resident_id: id } }
    rows.find { |row| row[:resident_id] == bob.id }.merge!(amount: '20.00', no_cost: false)

    patch "/api/v1/meals/#{meal.id}/bills", params: { bills: rows, token: token }

    expect(response).to have_http_status(:ok)
    expect(meal.bills.reload.to_h { |bill| [bill.resident_id, bill.amount] })
      .to eq(carol.id => BigDecimal('40'), bob.id => BigDecimal('20'))
  end
end

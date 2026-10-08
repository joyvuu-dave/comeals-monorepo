# frozen_string_literal: true

require 'rails_helper'

# The meal form (GET /meals/:id/cooks) and the bills save (PATCH
# /meals/:id/bills) are used together. Before #91 the form left out a
# retired cook who did not eat, so the page did not show that bill, and
# a save from the page then deleted it: a save listed every cook, and the
# server removed any cook the list left out. Since #135 a save names only
# the cooks it changes, so a cook the page does not show is never named
# and never touched. This spec saves the way the page does: one edit for
# the cook whose cost the person typed, with the values the form showed.
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
    shown = response.parsed_body['bills'].find { |row| row['resident_id'] == bob.id }
    edit = { op: 'change', resident_id: bob.id, from: shown.slice('amount', 'no_cost'),
             to: { amount: '20.00', no_cost: false } }

    patch "/api/v1/meals/#{meal.id}/bills", params: { edits: [edit], token: token }, headers: BillEdits.key_header,
                                            as: :json

    expect(response).to have_http_status(:ok)
    expect(meal.bills.reload.to_h { |bill| [bill.resident_id, bill.amount] })
      .to eq(carol.id => BigDecimal('40'), bob.id => BigDecimal('20'))
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Two people have the same meal page open (#135). Each page loaded the
# meal form (GET /meals/:id/cooks). A bills save (PATCH /meals/:id/bills)
# names only the cooks the person changed, and for a change or a remove it
# sends the amount and no_cost that page saw. A cook the save does not
# name is never touched.
#
# A saves first. B's page has not loaded the meal again yet (a live update
# is a job, then Pusher, then a GET), so B's save is built from the form
# as B loaded it, before A's save.
RSpec.describe 'Two pages save the same meal\'s bills, one from an old form' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:alice) { create(:resident, community: community, unit: unit, name: 'Alice') }
  let(:bob) { create(:resident, community: community, unit: unit, name: 'Bob') }
  let(:xavier) { create(:resident, community: community, unit: unit, name: 'Xavier') }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }
  let(:twenty_five) { { amount: '25.00', no_cost: false } }

  before { create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('0')) }

  def load_form(as:)
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: as.keys.first.token }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  # A cook's values as the form shows them: what the page sends in "from".
  def seen(form, cook)
    bill = form['bills'].find { |row| row['resident_id'] == cook.id }
    { amount: bill['amount'], no_cost: bill['no_cost'] }
  end

  def save(edits, as:)
    patch "/api/v1/meals/#{meal.id}/bills", params: { edits: edits, token: as.keys.first.token },
                                            headers: BillEdits.key_header, as: :json
  end

  def stored_bills
    meal.bills.reload.to_h { |bill| [bill.resident_id, bill.amount] }
  end

  it 'keeps the cook A added when B saves from a form loaded before A\'s save' do
    b_form = load_form(as: bob)
    save([{ op: 'add', resident_id: xavier.id, to: { amount: '30.00', no_cost: false } }], as: alice)
    expect(response).to have_http_status(:ok)

    save([{ op: 'change', resident_id: bob.id, from: seen(b_form, bob), to: twenty_five }], as: bob)

    expect(response).to have_http_status(:ok)
    expect(stored_bills).to eq(bob.id => BigDecimal('25'), xavier.id => BigDecimal('30'))
  end

  it 'does not bring back the cook A removed when B saves from a form loaded before A\'s save' do
    create(:bill, meal: meal, resident: xavier, community: community, amount: BigDecimal('0'))
    a_form = load_form(as: alice)
    b_form = load_form(as: bob)
    save([{ op: 'remove', resident_id: xavier.id, from: seen(a_form, xavier) }], as: alice)
    expect(response).to have_http_status(:ok)

    save([{ op: 'change', resident_id: bob.id, from: seen(b_form, bob), to: twenty_five }], as: bob)

    expect(response).to have_http_status(:ok)
    expect(stored_bills).to eq(bob.id => BigDecimal('25'))
  end

  it 'refuses B\'s change of a cost A changed first, names the cook, and writes nothing' do
    a_form = load_form(as: alice)
    b_form = load_form(as: bob)
    save([{ op: 'change', resident_id: bob.id, from: seen(a_form, bob),
            to: { amount: '10.00', no_cost: false } }], as: alice)
    expect(response).to have_http_status(:ok)

    save([{ op: 'change', resident_id: bob.id, from: seen(b_form, bob), to: twenty_five }], as: bob)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')
    expect(response.parsed_body['message']).to eq(
      "Nothing was saved, because this meal changed after you loaded it: Bob's cost changed. " \
      'Check the cooks and costs, then enter your change again.'
    )
    expect(stored_bills).to eq(bob.id => BigDecimal('10'))
  end

  # A page from before this change sends every cook it shows, and the
  # server used to delete the bill of any cook the list left out. Xavier's
  # bill stands for the one A just added; how A's page saved it does not
  # change what B's old page does to it.
  it 'refuses a save from a page that still sends the whole list, so it cannot delete the cook A added' do
    b_form = load_form(as: bob)
    create(:bill, meal: meal, resident: xavier, community: community, amount: BigDecimal('30'))

    rows = b_form['bills'].map { |bill| { resident_id: bill['resident_id'], amount: '25.00', no_cost: false } }
    patch "/api/v1/meals/#{meal.id}/bills", params: { bills: rows, token: bob.keys.first.token }, as: :json

    expect(stored_bills).to eq(bob.id => BigDecimal('0'), xavier.id => BigDecimal('30'))
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq(
      'message' => 'Nothing was saved, because this page is out of date. ' \
                   'Please reload the page and enter the costs again.',
      'type' => 'outdated'
    )
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The admin bill forms have a "No cost" check box, like the cook's row on
# the meal page. Since 2026-10-10 a wrong cook is fixed by deleting the
# bill and adding a new one (Bill::COOK_AND_MEAL_FIXED). Before the check
# box, a no-cost bill added again that way came back as a $0 bill not
# marked no-cost: the meal page showed the cook as missing a cost, the
# dashboard left the meal out as waiting for a cost, and the settlement
# preview warned about it.
RSpec.describe 'Admin bill no cost' do
  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:unit) { create(:unit, community: community, name: 'C') }
  let(:jane) { create(:resident, community: community, unit: unit, name: 'Jane Smith') }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 11, 5)) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  def page
    response.parsed_body
  end

  def no_cost_box
    page.at_css('input[type=checkbox]#bill_no_cost')
  end

  it 'shows an unchecked No cost box on the new bill form' do
    get '/bills/new'

    expect(page.at_css('#bill_no_cost_input').text.squish).to start_with('No cost')
    expect(no_cost_box['checked']).to be_nil
  end

  it 'shows the box checked on the edit form of a no-cost bill' do
    bill = create(:bill, meal: meal, resident: jane, community: community, amount: 0, no_cost: true)

    get "/bills/#{bill.id}/edit"

    expect(no_cost_box['checked']).to eq('checked')
  end

  it 'adds a bill marked no cost' do
    post '/bills', params: { bill: { meal_id: meal.id, resident_id: jane.id, amount: '0', no_cost: '1' } }

    expect(meal.bills.reload.map { |bill| [bill.resident_id, bill.amount, bill.no_cost] })
      .to eq([[jane.id, BigDecimal('0'), true]])
  end

  # The hint said "The meal's cost leaves out a no-cost bill, even if it
  # has an amount" until 2026-10-10. A no-cost bill cannot have one now.
  it 'says in the hint that a no-cost bill has no amount' do
    get '/bills/new'

    expect(page.at_css('#bill_no_cost_input .inline-hints').text.squish)
      .to eq("Check this box when the cook spent nothing. A bill marked No cost can't have an amount.")
  end

  # "No cost" means the cook spent nothing (Bill::NO_COST_MEANS_NO_AMOUNT).
  # Both forms answer with the sentence and save nothing.
  it 'refuses a new bill marked no cost with an amount, in words' do
    post '/bills', params: { bill: { meal_id: meal.id, resident_id: jane.id, amount: '86', no_cost: '1' } }

    expect(response).to have_http_status(:ok)
    expect(page.at_css('ul.errors').text.squish).to eq(Bill::NO_COST_MEANS_NO_AMOUNT)
    expect(meal.bills.reload).to be_empty
  end

  it 'refuses marking a bill with an amount no cost from the edit form, in words, and keeps the bill' do
    bill = create(:bill, meal: meal, resident: jane, community: community, amount: BigDecimal('86'))

    patch "/bills/#{bill.id}", params: { bill: { amount: '86.00', no_cost: '1' } }

    expect(response).to have_http_status(:ok)
    expect(page.at_css('ul.errors').text.squish)
      .to eq("A bill marked No cost can't have an amount. Clear the amount, or turn No cost off.")
    expect(bill.reload).to have_attributes(amount: BigDecimal('86'), no_cost: false)
  end

  it 'marks a saved bill no cost, and clears the mark, from the edit form' do
    bill = create(:bill, meal: meal, resident: jane, community: community, amount: 0)

    patch "/bills/#{bill.id}", params: { bill: { amount: '0', no_cost: '1' } }
    expect(response).to redirect_to("/bills/#{bill.id}")
    expect(bill.reload.no_cost).to be(true)

    patch "/bills/#{bill.id}", params: { bill: { amount: '0', no_cost: '0' } }
    expect(bill.reload.no_cost).to be(false)
  end
end

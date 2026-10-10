# frozen_string_literal: true

require 'rails_helper'

# A saved bill keeps its cook and its meal (Bill::COOK_AND_MEAL_FIXED).
# The admin edit form shows both as plain text, and only the amount can
# change there. To fix a wrong cook, an admin deletes the bill and adds a
# new one. Before 2026-10-10 the form had a menu for each, and a new cook
# chosen there made the meal history say "unknown bill changed".
RSpec.describe 'Admin bill cook and meal' do
  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:unit) { create(:unit, community: community, name: 'C') }
  let(:jane) { create(:resident, community: community, unit: unit, name: 'Jane Smith') }
  let!(:bob) { create(:resident, community: community, unit: unit, name: 'Bob Jones') }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 11, 5)) }
  let!(:bill) { create(:bill, meal: meal, resident: jane, community: community, amount: BigDecimal('40')) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  def page
    response.parsed_body
  end

  it 'shows the cook and the meal on the edit form as text, with no menu to change them' do
    get "/bills/#{bill.id}/edit"

    expect(page.css('#bill_meal_id, #bill_resident_id, select')).to be_empty
    expect(page.at_css('#bill_meal_input').text.squish).to eq('Common Meal Date Thu, Nov 5 2026')
    expect(page.at_css('#bill_resident_input').text.squish)
      .to eq('Cook Jane Smith - C To change the cook or the meal, delete this bill and add a new one.')
    expect(page.at_css('#bill_amount')['value']).to eq('40.00')
  end

  # The edit form tells the admin to delete the bill, so the Delete button
  # is on that page too, not only on the bill's own page.
  it 'offers Delete on the edit page' do
    get "/bills/#{bill.id}/edit"

    link = page.css('.action_items a').find { |a| a.text == 'Delete Bill' }
    expect(link).to be_present
    expect(link['href']).to eq("/bills/#{bill.id}")
    expect(link['data-method']).to eq('delete')
  end

  it 'keeps both menus on the new bill form' do
    get '/bills/new'

    expect(page.css('select#bill_meal_id option').map(&:text)).to include('Thu, Nov 5 2026')
    expect(page.css('select#bill_resident_id option').map(&:text)).to include('Jane Smith - C', 'Bob Jones - C')
    expect(page.text).not_to include('delete this bill')
  end

  it 'saves a new amount from the edit form' do
    patch "/bills/#{bill.id}", params: { bill: { amount: '45.50' } }

    expect(response).to redirect_to("/bills/#{bill.id}")
    expect(bill.reload).to have_attributes(amount: BigDecimal('45.5'), resident_id: jane.id, meal_id: meal.id)
  end

  # The form no longer sends a cook or a meal. A request that does is
  # refused in words on the form, not with a 500, and changes nothing.
  it 'refuses a new cook or a new meal sent to the edit form, in words, and changes nothing' do
    other_meal = create(:meal, community: community, date: Date.new(2026, 11, 6))

    [{ resident_id: bob.id }, { meal_id: other_meal.id }].each do |move|
      patch "/bills/#{bill.id}", params: { bill: move.merge(amount: '50') }

      expect(response).to have_http_status(:ok)
      expect(page.at_css('ul.errors').text.squish).to eq(Bill::COOK_AND_MEAL_FIXED)
      # The form still shows the cook and meal the bill has, not the ones asked for.
      expect(page.at_css('#bill_meal_input').text.squish).to eq('Common Meal Date Thu, Nov 5 2026')
      expect(page.at_css('#bill_resident_input').text.squish).to start_with('Cook Jane Smith - C')
      expect(bill.reload).to have_attributes(amount: BigDecimal('40'), resident_id: jane.id, meal_id: meal.id)
    end
  end

  it 'fixes a wrong cook by deleting the bill and adding a new one, and the history names both' do
    delete "/bills/#{bill.id}"
    post '/bills', params: { bill: { meal_id: meal.id, resident_id: bob.id, amount: '40' } }

    expect(meal.bills.reload.map { |kept| [kept.resident_id, kept.amount] }).to eq([[bob.id, BigDecimal('40')]])
    expect(AuditSerializer.new(meal.total_audits).to_h.pluck(:description))
      .to include('Jane removed as cook', 'Bob added as cook')
  end
end

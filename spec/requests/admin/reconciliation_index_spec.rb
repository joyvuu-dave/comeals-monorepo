# frozen_string_literal: true

require 'rails_helper'

# The reconciliations list shows how many dinners each settlement settled.
# prosopite watches every request (spec/support/prosopite.rb), so this
# example fails if the list counts each row's dinners with its own query.
RSpec.describe 'Admin Reconciliation Index' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:token) { 'test-readonly-token' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
  end

  # Settles `count` dinners, all in one month, one settlement for the month.
  def settle_month(month, count)
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit)
    eater = create(:resident, community: community, unit: unit)
    count.times do |day|
      meal = create(:meal, community: community, date: month + day)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
    settle!(cutoff: month.end_of_month)
  end

  it 'shows the number of dinners in each settlement' do
    settle_month(Date.new(2025, 1, 1), 1)
    settle_month(Date.new(2025, 2, 1), 2)
    settle_month(Date.new(2025, 3, 1), 3)

    get '/reconciliations', params: { token: token }, headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    counts = response.parsed_body.css('table.index_table tbody tr').map do |row|
      row.at_css('td.col-number_of_meals').text.strip
    end
    expect(counts).to contain_exactly('1', '2', '3')
  end
end

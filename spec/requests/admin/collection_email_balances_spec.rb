# frozen_string_literal: true

require 'rails_helper'

# The collection email goes to the common house after a settlement. It
# used to say "Here are the final balances" and link to the admin
# residents list, which shows the running balance: BalanceRecalculation
# fills it from the meals NOT yet settled, and SettleAndNotify reruns it
# right after the settlement, so the link showed $0.00 for a person who
# owed $30.00 in it (#165). Now the email lists the settlement's own
# numbers (ADR 0011 rule 9) and links to the settlement's page, and both
# say what the common house collects.
RSpec.describe 'Collection email balances' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:token) { 'test-readonly-token' }

  before do
    host! 'admin.example.com'
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
  end

  # The path and query of the settlement page link in the text part, so
  # the request goes to the admin host set above.
  def settlement_link(mail)
    uri = URI(mail.text_part.body.to_s[/^The settlement's page shows the meals in it: (\S+)$/, 1])
    "#{uri.path}?#{uri.query}"
  end

  def row_for(name)
    response.parsed_body.css('tr').find { |row| row.text.include?(name) }&.text&.squish
  end

  it 'says what each person owes in the settlement, in the email and on the page it links to' do
    unit = create(:unit, community: community, name: 'Elm')
    cook = create(:resident, community: community, unit: unit, name: 'Casey Cook', multiplier: 2)
    eater = create(:resident, community: community, unit: unit, name: 'Dana Diner', multiplier: 2)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    reconciliation = SettleAndNotify.call(cutoff: Date.new(2025, 3, 31)).reconciliation

    mail = ReconciliationMailer.common_house_collection_email(reconciliation)
    expect(mail.text_part.body.decoded).to include('- Dana Diner: owes $30.00')

    get settlement_link(mail)

    expect(response).to have_http_status(:ok)
    expect(row_for('Dana Diner')).to include('owes $30.00')
  end
end

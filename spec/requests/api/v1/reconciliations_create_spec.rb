# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/reconciliations' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:token) { resident.keys.first.token }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain
  end

  def settle(cutoff)
    post '/api/v1/reconciliations', params: { cutoff: cutoff.to_s },
                                    headers: { 'Authorization' => "Bearer #{token}" }
    response.parsed_body
  end

  def settleable_meal(date = Date.yesterday)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: resident, community: community, multiplier: 2)
    meal
  end

  it 'settles the period the same way the nightly task does: claims, ledger, balances, mail' do
    meal = settleable_meal
    later = settleable_meal(Time.zone.today)

    body = settle(Date.yesterday)

    expect(response).to have_http_status(:created)
    reconciliation = Reconciliation.order(:id).last
    expect(body.deep_symbolize_keys).to eq(id: reconciliation.id, date: Time.zone.today.iso8601,
                                           cutoff_date: Date.yesterday.iso8601, meal_count: 1)

    expect(reconciliation.meals).to contain_exactly(meal)
    expect(later.reload.reconciliation_id).to be_nil
    expect(reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('30'), resident.id => BigDecimal('-30'))
    expect(MealCharge.for_reconciliation(reconciliation).count).to eq(2)

    # The running balance no longer counts the settled meal, only today's.
    expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('-30'))
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
  end

  it 'refuses a cutoff that is not in the past, and writes nothing' do
    settleable_meal

    expect { settle(Time.zone.today) }.not_to change(Reconciliation, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to eq('End date must be in the past')
  end

  it 'refuses a period with nothing to settle' do
    settle(Date.yesterday)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to include('must settle at least one meal')
  end

  it 'refuses a cutoff that is not a date' do
    post '/api/v1/reconciliations', params: { cutoff: 'soon' }, headers: { 'Authorization' => "Bearer #{token}" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
  end

  it 'answers 409 when another settlement got there first' do
    settleable_meal
    allow(Settlement).to receive(:run!).and_raise(Settlement::Contested,
                                                  'a concurrent reconciliation settled the rest first')

    settle(Date.yesterday)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body[:message]).to match(/Nothing was saved. Try again./)
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end

  it 'answers 409 when the database refused the transaction for a conflict' do
    settleable_meal
    allow(Settlement).to receive(:run!).and_raise(ActiveRecord::SerializationFailure, 'could not serialize')

    settle(Date.yesterday)

    expect(response).to have_http_status(:conflict)
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/reconciliations' do
  include ActiveJob::TestHelper

  # The cook mail is a job (NotifyCooksJob). Run it inline so these examples
  # see the whole of what a settlement does.
  around { |example| perform_enqueued_jobs { example.run } }

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2, can_reconcile: true) }
  let(:token) { resident.keys.first.token }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule 2).
  let(:latest) { community.today - 14 }

  before do
    allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain
  end

  def settle(cutoff)
    post '/api/v1/reconciliations', params: { cutoff: cutoff.to_s },
                                    headers: { 'Authorization' => "Bearer #{token}" }
    response.parsed_body
  end

  def settleable_meal(date = latest)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: resident, community: community)
    meal
  end

  it 'settles the period the same way the rake task does: claims, ledger, balances, mail' do
    meal = settleable_meal
    later = settleable_meal(latest + 1)

    body = settle(latest)

    expect(response).to have_http_status(:created)
    reconciliation = Reconciliation.order(:id).last
    expect(body.deep_symbolize_keys).to eq(id: reconciliation.id, date: Time.zone.today.iso8601,
                                           cutoff_date: latest.iso8601, meal_count: 1)

    expect(reconciliation.meals).to contain_exactly(meal)
    expect(later.reload.reconciliation_id).to be_nil
    expect(reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('30'), resident.id => BigDecimal('-30'))
    expect(MealCharge.for_reconciliation(reconciliation).count).to eq(2)

    # The running balance no longer counts the settled meal, only the newer one.
    expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('-30'))
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
  end

  it 'answers as soon as the ledger and balances are written; the cook mail is a job' do
    settleable_meal
    # Not performed inline here: this example is about what the request
    # itself does.
    queue_adapter.perform_enqueued_jobs = false

    settle(latest)

    expect(response).to have_http_status(:created)
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
    expect(NotifyCooksJob).to have_been_enqueued.with(Reconciliation.last).once
    expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
  end

  it 'enqueues no mail when the settlement was refused' do
    queue_adapter.perform_enqueued_jobs = false

    settle(latest)

    expect(response).to have_http_status(:bad_request)
    expect(NotifyCooksJob).not_to have_been_enqueued
  end

  # The caller sent `cutoff`, so the answer names `cutoff`, in the same
  # words the preview answers for the same day. The row's own name for it
  # (end_date) is not part of the API.
  it 'refuses a cutoff less than 14 days back, in the words the preview uses, and writes nothing' do
    settleable_meal(latest + 1)
    refusal = "cutoff must be on or before #{latest.iso8601}, 14 days before today"

    [latest + 1, community.today, community.today + 1].each do |cutoff|
      get '/api/v1/reconciliations/preview', params: { cutoff: cutoff.iso8601 },
                                             headers: { 'Authorization' => "Bearer #{token}" }
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq(refusal)

      expect { settle(cutoff) }.not_to change(Reconciliation, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq(refusal)
    end
  end

  it 'refuses a period with nothing to settle' do
    settle(latest)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to eq('No unreconciled meals with bills on or before this date. A ' \
                                                 'reconciliation must settle at least one meal or carry a correction.')
  end

  # The cook spent $30 and only a baby ate, so the meal is held back. The
  # answer names it, and does not say there are no meals with bills.
  it 'refuses a period whose only meal with a bill is held back, and names that meal' do
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    baby = create(:resident, community: community, unit: unit, multiplier: 0)
    create(:meal_resident, meal: meal, resident: baby, community: community)

    expect { settle(latest) }.not_to change(Reconciliation, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message])
      .to eq('No meal on or before this date can be settled yet. Meals held back because a bill has money on ' \
             "it and nobody who pays is signed up: #{latest.iso8601}. To settle one, sign up someone " \
             'who pays or remove the bill. A reconciliation must settle at least one meal or carry a correction.')
    expect(meal.reload.reconciliation_id).to be_nil
  end

  # A second cook has not said what they spent, so the meal waits (ADR
  # 0011 rule 3). The answer names it.
  it 'refuses a period whose only meal waits for a cost, and names that meal' do
    meal = settleable_meal
    create(:bill, meal: meal, resident: resident, community: community, amount: 0)

    expect { settle(latest) }.not_to change(Reconciliation, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message])
      .to eq("No meal on or before this date can be settled yet. Meals waiting for a cook's cost: " \
             "#{latest.iso8601}. To settle one, each of its cooks enters a cost or marks No cost. " \
             'A reconciliation must settle at least one meal or carry a correction.')
    expect(meal.reload.reconciliation_id).to be_nil
  end

  it 'refuses a cutoff that is not a date' do
    post '/api/v1/reconciliations', params: { cutoff: 'soon' }, headers: { 'Authorization' => "Bearer #{token}" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
  end

  # Date.iso8601 read a day before October 15, 1582 in the Julian
  # calendar, and PostgreSQL reads it in the Gregorian one. February 29,
  # 1500 is a Julian leap day the Gregorian calendar does not have, so
  # the database refused the query and the answer was a 500
  # (YearMonthDay reads the day in the Gregorian calendar).
  it 'refuses a day only the Julian calendar has' do
    settle('1500-02-29')

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
  end

  # public/api.md says the cutoff is YYYY-MM-DD (YearMonthDay). Until
  # 2026-10-16 Date.iso8601 also took "--10-12", with no year, and filled
  # the year in from the machine's own clock, not from the community's
  # today; and "2026-10", with no day, which it read as the 1st. On
  # October 20, 2026, "2026-10" settled the dinner of September 30, and a
  # settlement has no undo.
  describe 'a cutoff with no year or no day' do
    include ActiveSupport::Testing::TimeHelpers

    it 'is refused, and nothing is settled', :aggregate_failures do
      travel_to Time.zone.local(2026, 10, 20, 12, 0) do
        meal = settleable_meal(Date.new(2026, 9, 30))

        %w[--10-12 2026-10].each do |cutoff|
          settle(cutoff)

          expect(response).to have_http_status(:bad_request), "cutoff #{cutoff}"
          expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD'), "cutoff #{cutoff}"
        end
        expect(meal.reload.reconciliation_id).to be_nil
      end
    end
  end

  it 'answers 409 when another settlement got there first' do
    settleable_meal
    allow(Settlement).to receive(:settle!).and_raise(Settlement::Contested,
                                                     'a concurrent reconciliation settled the rest first')

    settle(latest)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body[:message]).to match(/Nothing was saved. Try again./)
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end

  it 'answers 409 when the database refused the transaction for a conflict' do
    settleable_meal
    allow(Settlement).to receive(:settle!).and_raise(ActiveRecord::SerializationFailure, 'could not serialize')

    settle(latest)

    expect(response).to have_http_status(:conflict)
  end

  # The settle button is a person waiting, and the web dyno serves one
  # request at a time (config/puma.rb). The nightly task's ten tries sleep
  # two to four minutes all told, which would hold the only thread and stop
  # the app for everyone, while Heroku's router gave up at 30 seconds and
  # showed an error for a settlement that was still running. Found by
  # bin/storm at 128 clients, 2026-09-11.
  #
  # Without a test transaction, because RetryOnConflict does not retry
  # inside one — it cannot, a refused transaction is done for.
  describe 'when the settlement keeps conflicting' do
    include_context 'with no test transaction'

    it 'gives up after three tries and answers 409, instead of waiting minutes' do
      settleable_meal
      allow(RetryOnConflict).to receive(:sleep)
      allow(Settlement).to receive(:settle!).and_raise(ActiveRecord::SerializationFailure, 'could not serialize')

      settle(latest)

      expect(response).to have_http_status(:conflict)
      expect(Settlement).to have_received(:settle!).exactly(3).times
      expect(Reconciliation.count).to eq(0)
    end
  end
end

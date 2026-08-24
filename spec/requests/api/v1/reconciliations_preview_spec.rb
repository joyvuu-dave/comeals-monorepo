# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/reconciliations/preview' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: '5B') }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2, can_reconcile: true) }
  let(:token) { resident.keys.first.token }

  def preview(cutoff = Date.yesterday)
    get '/api/v1/reconciliations/preview', params: { cutoff: cutoff.to_s },
                                           headers: { 'Authorization' => "Bearer #{token}" }
    response.parsed_body
  end

  def money(value)
    BigDecimal(value)
  end

  it 'shows what a settlement would claim and store, and writes nothing' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Alice Cook')
    other_unit = create(:unit, community: community, name: '7A')
    eater = create(:resident, community: community, unit: other_unit, multiplier: 2, name: 'Bob Eater')
    meal = create(:meal, community: community, date: Date.yesterday - 1, description: 'Thursday Dinner')
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: resident, community: community, multiplier: 2)
    create(:guest, meal: meal, resident: eater, multiplier: 2)

    body = nil
    expect { body = preview }
      .not_to(change do
                [Reconciliation.count, MealCharge.count, ReconciliationBalance.count,
                 Meal.where.not(reconciliation_id: nil).count]
              end)

    expect(response).to have_http_status(:ok)
    expect(body[:cutoff_date]).to eq(Date.yesterday.iso8601)
    expect(body[:summary]).to include(meal_count: 1, residents_affected: 3, units_affected: 2,
                                      earliest_meal_date: meal.date.iso8601, latest_meal_date: meal.date.iso8601)
    expect(money(body[:summary][:total_cost])).to eq(30)

    shown = body[:meals].first
    expect(shown).to include(id: meal.id, date: meal.date.iso8601, description: 'Thursday Dinner',
                             capped: false, subsidized: false, total_multiplier: 6, attendee_count: 2, guest_count: 1)
    expect(money(shown[:total_cost])).to eq(30)
    expect(money(shown[:unit_cost])).to eq(5)
    expect(shown[:cooks].map(&:deep_symbolize_keys)).to eq([{ resident_id: cook.id, name: 'Alice Cook',
                                                              bill_amount: '30.0', no_cost: false }])

    residents = body[:balances][:residents].index_by { |row| row[:resident_id] }
    expect(money(residents[cook.id][:amount])).to eq(30)
    expect(money(residents[eater.id][:amount])).to eq(-20)
    expect(money(residents[resident.id][:amount])).to eq(-10)
    expect(residents[eater.id]).to include(name: 'Bob Eater', unit_id: other_unit.id, unit_name: '7A')

    units = body[:balances][:units].index_by { |row| row[:unit_name] }
    expect(money(units['5B'][:amount])).to eq(20)
    expect(units['5B'][:resident_count]).to eq(2)
    expect(money(units['7A'][:amount])).to eq(-20)
    expect(body[:warnings]).to eq([])
  end

  it 'answers with empty lists when nothing is settleable' do
    body = preview

    expect(response).to have_http_status(:ok)
    expect(body[:summary]).to include(meal_count: 0, residents_affected: 0, units_affected: 0,
                                      earliest_meal_date: nil, latest_meal_date: nil)
    expect(body[:meals]).to eq([])
    expect(body[:balances][:residents]).to eq([])
    expect(body[:warnings]).to eq([])
  end

  it 'uses the exact scope a settlement claims: not today, not after the cutoff, not without a bill' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    inside = create(:meal, community: community, date: Date.yesterday - 2)
    create(:bill, meal: inside, resident: cook, community: community, amount: BigDecimal('10'))
    past_cutoff = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: past_cutoff, resident: cook, community: community, amount: BigDecimal('10'))
    today = create(:meal, community: community, date: Time.zone.today)
    create(:bill, meal: today, resident: cook, community: community, amount: BigDecimal('10'))
    no_bill = create(:meal, community: community, date: Date.yesterday - 3)
    create(:meal_resident, meal: no_bill, resident: resident, community: community, multiplier: 2)

    body = preview(Date.yesterday - 1)

    expect(body[:meals].pluck(:id)).to eq([inside.id])
  end

  describe 'warnings' do
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Charlie Cook') }

    it 'flags a bill on a meal nobody attended' do
      meal = create(:meal, community: community, date: Date.yesterday)
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('45'))

      expected = {
        id: "bill_with_no_attendees:meal=#{meal.id}:bill=#{bill.id}",
        kind: 'bill_with_no_attendees',
        severity: 'warning',
        meal_id: meal.id,
        title: 'Bill with no attendees',
        body: 'Charlie Cook submitted a $45.00 bill for a meal with zero attendees.'
      }
      expect(preview[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
    end

    it 'flags a meal people ate that no cook billed — a meal the settlement would leave behind' do
      billed = create(:meal, community: community, date: Date.yesterday - 1)
      create(:bill, meal: billed, resident: cook, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: billed, resident: resident, community: community, multiplier: 2)
      unbilled = create(:meal, community: community, date: Date.yesterday)
      create(:meal_resident, meal: unbilled, resident: resident, community: community, multiplier: 2)
      create(:guest, meal: unbilled, resident: resident, multiplier: 2)
      # Not in the period, and nobody ate: neither is a warning.
      create(:meal_resident, meal: create(:meal, community: community, date: Time.zone.today),
                             resident: resident, community: community, multiplier: 2)
      create(:meal, community: community, date: Date.yesterday - 2)

      body = preview
      expect(body[:meals].pluck(:id)).to eq([billed.id])
      expected = {
        id: "attendance_without_bill:meal=#{unbilled.id}",
        kind: 'attendance_without_bill',
        severity: 'warning',
        meal_id: unbilled.id,
        title: 'Attendance without bill',
        body: "2 people signed up to eat on #{unbilled.date.iso8601}, but no bill was submitted. " \
              'This meal will not be settled until a cook enters a bill.'
      }
      expect(body[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
    end

    it 'flags a $0 bill that was not marked no-cost, and not one that was' do
      meal = create(:meal, community: community, date: Date.yesterday)
      zero = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))
      helper = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: helper, community: community, amount: BigDecimal('0'), no_cost: true)
      create(:meal_resident, meal: meal, resident: resident, community: community, multiplier: 2)

      expected = {
        id: "zero_bill_not_flagged:meal=#{meal.id}:bill=#{zero.id}",
        kind: 'zero_bill_not_flagged',
        severity: 'info',
        meal_id: meal.id,
        title: "Bill of $0 not flagged as 'no cost'",
        body: "Charlie Cook submitted a $0.00 bill but didn't mark it as a no-cost meal."
      }
      expect(preview[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
    end
  end

  describe 'bad input' do
    it 'refuses a cutoff of today, the same way a settlement does' do
      preview(Time.zone.today)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq('cutoff must be in the past')
    end

    it 'refuses a cutoff that is not a date' do
      get '/api/v1/reconciliations/preview', params: { cutoff: 'yesterday' },
                                             headers: { 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
    end

    it 'refuses a missing cutoff' do
      get '/api/v1/reconciliations/preview', headers: { 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:bad_request)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/reconciliations/preview' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: '5B') }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2, can_reconcile: true) }
  let(:token) { resident.keys.first.token }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule 2).
  let(:latest) { community.today - 14 }

  def preview(cutoff = latest)
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
    meal = create(:meal, community: community, date: latest - 1, description: 'Thursday Dinner')
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:meal_resident, meal: meal, resident: resident, community: community)
    create(:guest, meal: meal, resident: eater, multiplier: 2)

    body = nil
    expect { body = preview }
      .not_to(change do
                [Reconciliation.count, MealCharge.count, ReconciliationBalance.count,
                 Meal.where.not(reconciliation_id: nil).count]
              end)

    expect(response).to have_http_status(:ok)
    expect(body[:cutoff_date]).to eq(latest.iso8601)
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
    expect(residents.values.pluck(:lived_here)).to all(be(true))
    expect(body[:balances][:moved_out]).to eq('amount' => '0.0', 'resident_count' => 0)
    expect(body[:warnings]).to eq([])
  end

  # ADR 0011 rule 7: the preview says what the settlement would save. Bob
  # has moved out: he is in no unit, and moved_out has his amount, so the
  # units and moved_out add up to zero.
  it 'counts someone who has moved out under moved_out, not in their unit' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Alice Cook')
    other_unit = create(:unit, community: community, name: '7A')
    gone = create(:resident, community: community, unit: other_unit, multiplier: 2, name: 'Bob Eater')
    meal = create(:meal, community: community, date: latest - 1)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: gone, community: community)
    gone.update!(active: false)

    body = preview

    expect(body[:summary]).to include(residents_affected: 2, units_affected: 1)
    residents = body[:balances][:residents].index_by { |row| row[:resident_id] }
    expect(residents[gone.id]).to include(unit_name: '7A', lived_here: false)
    expect(residents[cook.id]).to include(lived_here: true)
    units = body[:balances][:units].to_h { |row| [row[:unit_name], [money(row[:amount]), row[:resident_count]]] }
    expect(units).to eq('5B' => [30, 1], '7A' => [0, 0])
    expect(body[:balances][:moved_out]).to eq('amount' => '-30.0', 'resident_count' => 1)
  end

  # A correction to a dinner already settled (ADR 0011 rule 6): its
  # changes are in the balances, and the list says where they come from.
  it 'lists the corrections a settlement would carry, with their words' do
    cook = create(:resident, community: community, unit: unit, name: 'Alice Cook')
    meal = create(:meal, community: community, date: latest - 3)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: resident, community: community)
    settle!(cutoff: latest - 3)
    correction = MealCorrecting.save!(meal.reload, by: create(:admin_user, community: community),
                                                   reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end

    body = preview

    expect(body[:corrections].map(&:deep_symbolize_keys)).to eq(
      [{ id: correction.id, meal_id: meal.id, meal_date: meal.date.iso8601, reason: 'Typed $30 for $20',
         made_at: correction.created_at.utc.iso8601,
         edits: [{ what: 'cost', resident_id: cook.id, from: { amount: '30.0', no_cost: false },
                   to: { amount: '20.0', no_cost: false }, words: "Changed Alice Cook's cost from $30.00 to $20.00." }],
         changes: [{ resident_id: cook.id, name: 'Alice Cook', amount: '-10.0' },
                   { resident_id: resident.id, name: resident.name, amount: '10.0' }] }]
    )
    residents = body[:balances][:residents].index_by { |row| row[:resident_id] }
    expect(money(residents[cook.id][:amount])).to eq(-10)
    expect(money(residents[resident.id][:amount])).to eq(10)
  end

  it 'answers with empty lists when nothing is settleable' do
    body = preview

    expect(response).to have_http_status(:ok)
    expect(body[:summary]).to include(meal_count: 0, residents_affected: 0, units_affected: 0,
                                      earliest_meal_date: nil, latest_meal_date: nil)
    expect(body[:meals]).to eq([])
    expect(body[:balances][:residents]).to eq([])
    expect(body[:warnings]).to eq([])
    expect(body[:corrections]).to eq([])
  end

  it 'uses the exact scope a settlement claims: not today, not after the cutoff, not without a bill' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    inside = create(:meal, community: community, date: latest - 2)
    create(:bill, meal: inside, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: inside, resident: resident, community: community)
    past_cutoff = create(:meal, community: community, date: latest)
    create(:bill, meal: past_cutoff, resident: cook, community: community, amount: BigDecimal('10'))
    today = create(:meal, community: community, date: Time.zone.today)
    create(:bill, meal: today, resident: cook, community: community, amount: BigDecimal('10'))
    no_bill = create(:meal, community: community, date: latest - 3)
    create(:meal_resident, meal: no_bill, resident: resident, community: community)

    body = preview(latest - 1)

    expect(body[:meals].pluck(:id)).to eq([inside.id])
  end

  describe 'warnings' do
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Charlie Cook') }

    it 'holds back a bill on a meal nobody attended, and says so' do
      meal = create(:meal, community: community, date: latest)
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('45'))
      # Empty cook slots on a meal nobody attended settle with no effect and
      # get no such warning (the $0 one is the zero_bill_not_flagged below).
      empty = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: empty, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)

      body = preview
      expected = {
        id: "bill_with_no_attendees:meal=#{meal.id}:bill=#{bill.id}",
        kind: 'bill_with_no_attendees',
        severity: 'warning',
        meal_id: meal.id,
        title: 'Bill with no attendees',
        body: "Charlie Cook submitted a $45.00 bill for #{meal.date.iso8601}, but nobody signed up to eat. " \
              'This meal will not be settled until someone is signed up or the bill is removed.'
      }
      expect(body[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
      expect(body[:meals].pluck(:id)).to eq([empty.id])
    end

    # Only a free eater signed up, so nobody can be charged and the cook
    # would be credited $0 for good. The settlement holds the meal back,
    # and the preview says why and leaves its cost out of the total (#94).
    it 'holds back a bill on a meal only free eaters attended, and says so' do
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      meal = create(:meal, community: community, date: latest)
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('45'))
      create(:meal_resident, meal: meal, resident: baby, community: community)

      body = preview
      expected = {
        id: "bill_with_only_free_eaters:meal=#{meal.id}:bill=#{bill.id}",
        kind: 'bill_with_only_free_eaters',
        severity: 'warning',
        meal_id: meal.id,
        title: 'Bill with only free eaters',
        body: "Charlie Cook submitted a $45.00 bill for #{meal.date.iso8601}, but only people who eat free " \
              'signed up. This meal will not be settled until someone who pays is signed up or the bill is removed.'
      }
      expect(body[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
      expect(body[:meals]).to eq([])
      expect(money(body[:summary][:total_cost])).to eq(0)
    end

    it 'does not say a meal it claims will not be settled, for a $0 cook slot nobody ate' do
      meal = create(:meal, community: community, date: latest)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))

      body = preview
      settle!

      aggregate_failures do
        expect(body[:meals].pluck(:id)).to eq([meal.id])
        expect(meal.reload).to be_reconciled
        expect(body[:warnings].pluck(:kind)).to eq(%w[zero_bill_not_flagged])
      end
    end

    it 'flags a meal people ate that no cook billed — a meal the settlement would leave behind' do
      billed = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: billed, resident: cook, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: billed, resident: resident, community: community)
      unbilled = create(:meal, community: community, date: latest)
      create(:meal_resident, meal: unbilled, resident: resident, community: community)
      create(:guest, meal: unbilled, resident: resident, multiplier: 2)
      # Not in the period, and nobody ate: neither is a warning.
      create(:meal_resident, meal: create(:meal, community: community, date: Time.zone.today),
                             resident: resident, community: community, multiplier: 2)
      create(:meal, community: community, date: latest - 2)

      body = preview
      expect(body[:meals].pluck(:id)).to eq([billed.id])
      expected = {
        id: "attendance_without_bill:meal=#{unbilled.id}",
        kind: 'attendance_without_bill',
        severity: 'warning',
        meal_id: unbilled.id,
        title: 'Attendance without bill',
        body: "2 people signed up to eat on #{unbilled.date.iso8601}, but no bill was submitted. " \
              'This meal will not be settled until a cook enters a bill, or it is cancelled.'
      }
      expect(body[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
    end

    # Someone ate and a cook's cost is blank, so the settlement waits for
    # the cost (ADR 0011 rule 3). The preview says so, names the cook, and
    # leaves the meal out. The cook who marked No cost is not named.
    it 'leaves out a meal with a cost not entered, and says whose' do
      meal = create(:meal, community: community, date: latest)
      blank = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))
      helper = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: helper, community: community, amount: BigDecimal('0'), no_cost: true)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      body = preview
      expected = {
        id: "cost_not_entered:meal=#{meal.id}:bill=#{blank.id}",
        kind: 'cost_not_entered',
        severity: 'warning',
        meal_id: meal.id,
        title: 'Cost not entered',
        body: "Charlie Cook has not entered a cost for #{meal.date.iso8601}. This meal will not be settled " \
              'until they enter a cost or mark No cost.'
      }
      expect(body[:warnings].map(&:deep_symbolize_keys)).to eq([expected])
      expect(body[:meals]).to eq([])
    end

    it 'leaves a meal that waits for a cost out of the balances, and settles the others' do
      paid = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: paid, resident: cook, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: paid, resident: resident, community: community)
      waiting = create(:meal, community: community, date: latest)
      create(:bill, meal: waiting, resident: cook, community: community, amount: BigDecimal('50'))
      create(:bill, meal: waiting, resident: create(:resident, community: community, unit: unit),
                    community: community, amount: BigDecimal('0'))
      create(:meal_resident, meal: waiting, resident: resident, community: community)

      body = preview

      expect(body[:meals].pluck(:id)).to eq([paid.id])
      expect(money(body[:summary][:total_cost])).to eq(20)
      expect(body[:warnings].pluck(:kind)).to eq(%w[cost_not_entered])
    end
  end

  describe 'bad input' do
    it 'refuses a cutoff less than 14 days back, the same way a settlement does' do
      preview(latest + 1)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq("cutoff must be on or before #{latest.iso8601}, " \
                                                   '14 days before today')
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

    # public/api.md says the cutoff is YYYY-MM-DD (YearMonthDay). Until
    # 2026-10-16 Date.iso8601 also took "--10-12", with no year, and
    # filled the year in from the machine's own clock, not from the
    # community's today; and "2026-10", with no day, which it read as the
    # 1st. On October 20, 2026, "2026-10" was a cutoff 19 days back, and
    # the preview answered for October 1.
    describe 'a cutoff with no year or no day' do
      include ActiveSupport::Testing::TimeHelpers

      it 'is refused', :aggregate_failures do
        travel_to Time.zone.local(2026, 10, 20, 12, 0) do
          %w[--10-12 2026-10].each do |cutoff|
            preview(cutoff)

            expect(response).to have_http_status(:bad_request), "cutoff #{cutoff}"
            expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD'), "cutoff #{cutoff}"
          end
        end
      end
    end

    # Date.iso8601 read a day before October 15, 1582 in the Julian
    # calendar, and PostgreSQL reads it in the Gregorian one. February
    # 29, 1500 is a Julian leap day the Gregorian calendar does not have,
    # so the database refused the query and the answer was a 500
    # (YearMonthDay reads the day in the Gregorian calendar).
    it 'refuses a day only the Julian calendar has' do
      preview('1500-02-29')

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
    end

    # A cutoff sent as a list (cutoff[]=...) once reached Date.iso8601,
    # which raises TypeError for a list, and nothing turned that into a
    # 400.
    it 'refuses a cutoff sent as a list' do
      get '/api/v1/reconciliations/preview', params: { cutoff: [latest.iso8601] },
                                             headers: { 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:message]).to eq('cutoff must be a date, YYYY-MM-DD')
    end
  end
end

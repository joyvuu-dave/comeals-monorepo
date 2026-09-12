# frozen_string_literal: true

require 'rails_helper'

# The warnings a settlement preview shows, one rule each. The preview
# endpoint (spec/requests/api/v1/reconciliations_preview_spec.rb) proves
# they reach the client; this pins what each one says and when.
RSpec.describe ReconciliationWarnings do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook Person') }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  def bill(amount, no_cost: false)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount), no_cost: no_cost)
  end

  it 'warns about a bill with money on a meal nobody signed up for' do
    row = bill('12.50')

    warnings = described_class.for([meal])

    expect(warnings).to eq([{
                             id: "bill_with_no_attendees:meal=#{meal.id}:bill=#{row.id}",
                             kind: 'bill_with_no_attendees',
                             severity: 'warning', meal_id: meal.id, title: 'Bill with no attendees',
                             body: 'Cook Person submitted a $12.50 bill for 2026-04-10, but nobody signed up to eat. ' \
                                   'This meal will not be settled until someone is signed up or the bill is removed.'
                           }])
  end

  it 'counts a resident and a guest together, so a meal with one of each is not empty' do
    bill('12.50')
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:guest, meal: meal, resident: cook)

    expect(described_class.for([meal])).to be_empty
  end

  it 'does not take a no-cost bill for money because an amount was left on it' do
    bill('12', no_cost: true)

    expect(described_class.for([], held: [meal])).to be_empty
  end

  it 'counts a guest as someone who signed up' do
    bill('12.50')
    create(:guest, meal: meal, resident: cook)

    expect(described_class.for([meal])).to be_empty
  end

  it 'counts a resident as someone who signed up' do
    bill('12.50')
    create(:meal_resident, meal: meal, resident: cook, community: community)

    expect(described_class.for([meal])).to be_empty
  end

  it 'does not warn about a no-cost bill on an empty meal' do
    bill('0', no_cost: true)

    expect(described_class.for([meal])).to be_empty
  end

  it 'says a $0 bill was not flagged as no cost, on top of the empty-meal warning' do
    row = bill('0')

    expect(described_class.for([meal]).pluck(:kind))
      .to eq(%w[bill_with_no_attendees zero_bill_not_flagged])
    expect(described_class.for([meal]).last).to include(
      id: "zero_bill_not_flagged:meal=#{meal.id}:bill=#{row.id}", severity: 'info',
      title: "Bill of $0 not flagged as 'no cost'",
      body: "Cook Person submitted a $0.00 bill but didn't mark it as a no-cost meal."
    )
  end

  it 'describes a skipped meal as attendance without a bill, counting guests' do
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:guest, meal: meal, resident: cook)

    warnings = described_class.for([], skipped: [meal])

    expect(warnings).to eq([{
                             id: "attendance_without_bill:meal=#{meal.id}", kind: 'attendance_without_bill',
                             severity: 'warning',
                             meal_id: meal.id, title: 'Attendance without bill',
                             body: '2 people signed up to eat on 2026-04-10, but no bill was submitted. ' \
                                   'This meal will not be settled until a cook enters a bill.'
                           }])
  end

  it 'lists only the bills with money on a held meal, not the no-cost or $0 ones' do
    with_money = bill('8')
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('0'), no_cost: true)
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('0'), no_cost: false)

    warnings = described_class.for([], held: [meal])

    expect(warnings.pluck(:id)).to eq(["bill_with_no_attendees:meal=#{meal.id}:bill=#{with_money.id}"])
  end

  it 'can be called with nothing skipped or held' do
    expect(described_class.for([])).to eq([])
  end
end

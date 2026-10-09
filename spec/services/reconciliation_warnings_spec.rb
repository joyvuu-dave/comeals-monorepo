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

  it 'warns about a bill with money on a held meal nobody signed up for' do
    row = bill('12.50')

    warnings = described_class.for([], held: [meal])

    expect(warnings).to eq([{
                             id: "bill_with_no_attendees:meal=#{meal.id}:bill=#{row.id}",
                             kind: 'bill_with_no_attendees',
                             severity: 'warning', meal_id: meal.id, title: 'Bill with no attendees',
                             body: 'Cook Person submitted a $12.50 bill for 2026-04-10, but nobody signed up to eat. ' \
                                   'This meal will not be settled until someone is signed up or the bill is removed.'
                           }])
  end

  # Someone signed up, but everyone who did eats free, so nobody can be
  # charged and the settlement holds the meal back (#94). Saying "nobody
  # signed up" would be false.
  it 'warns about a bill with money on a held meal only free eaters signed up for' do
    row = bill('12.50')
    baby = create(:resident, community: community, unit: unit, multiplier: 0)
    create(:meal_resident, meal: meal, resident: baby, community: community)

    warnings = described_class.for([], held: [meal])

    expect(warnings).to eq([{
                             id: "bill_with_only_free_eaters:meal=#{meal.id}:bill=#{row.id}",
                             kind: 'bill_with_only_free_eaters',
                             severity: 'warning', meal_id: meal.id, title: 'Bill with only free eaters',
                             body: 'Cook Person submitted a $12.50 bill for 2026-04-10, but only people who eat ' \
                                   'free signed up. This meal will not be settled until someone who pays is ' \
                                   'signed up or the bill is removed.'
                           }])
  end

  it 'does not take a no-cost bill for money because an amount was left on it' do
    bill('12', no_cost: true)

    expect(described_class.for([], held: [meal])).to be_empty
  end

  it 'does not warn about a no-cost bill on an empty meal' do
    bill('0', no_cost: true)

    expect(described_class.for([meal])).to be_empty
  end

  # A claimed meal nobody ate holds only $0 or no-cost bills
  # (Meal.settleable_by) and settles with no effect, so the one thing to
  # say about it is the unmarked $0 bill (#96).
  it 'says only that a $0 bill was not flagged as no cost, on a claimed meal nobody ate' do
    row = bill('0')

    expect(described_class.for([meal])).to eq([{
                                                id: "zero_bill_not_flagged:meal=#{meal.id}:bill=#{row.id}",
                                                kind: 'zero_bill_not_flagged', severity: 'info', meal_id: meal.id,
                                                title: "Bill of $0 not flagged as 'no cost'",
                                                body: "Cook Person submitted a $0.00 bill but didn't mark it " \
                                                      'as a no-cost meal.'
                                              }])
  end

  it 'says a $0 bill was not flagged as no cost on a claimed meal people ate, next to a bill with money' do
    bill('20')
    zero = create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit),
                         community: community, amount: BigDecimal('0'))
    create(:meal_resident, meal: meal, resident: cook, community: community)

    expect(described_class.for([meal]).pluck(:id)).to eq(["zero_bill_not_flagged:meal=#{meal.id}:bill=#{zero.id}"])
  end

  it 'says nothing about a claimed meal with money on its bill and someone to charge' do
    bill('20')
    create(:meal_resident, meal: meal, resident: cook, community: community)

    expect(described_class.for([meal])).to be_empty
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

  # Two residents and one guest, so a count that read one list twice
  # would say 2 or 4, not 3.
  it 'counts residents and guests together on a skipped meal' do
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
    create(:guest, meal: meal, resident: cook)

    expect(described_class.for([], skipped: [meal]).first[:body]).to start_with('3 people signed up to eat')
  end

  it 'counts one guest alone as one person on a skipped meal' do
    create(:guest, meal: meal, resident: cook)

    expect(described_class.for([], skipped: [meal]).first[:body]).to start_with('1 person signed up to eat')
  end

  it 'counts one resident alone as one person on a skipped meal' do
    create(:meal_resident, meal: meal, resident: cook, community: community)

    expect(described_class.for([], skipped: [meal]).first[:body]).to start_with('1 person signed up to eat')
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

# frozen_string_literal: true

require 'rails_helper'

# The settlement specs in reconciliation_spec.rb use amounts picked to hit
# one branch of the rounding code, and most of them divide cleanly. Real
# receipts are not like that: a cook types in whatever the store charged.
# This file settles bills whose cent counts are awkward — many are prime,
# so no attendee count divides them evenly — and checks the two promises
# the money model makes, against numbers computed by hand:
#
#   - the rounded balances sum to exactly zero, and
#   - every rounded balance is within one cent of the exact full-precision
#     amount, with penny ties broken by lowest resident_id.
#
# The last example stops hand-computing and settles a whole batch of
# awkward meals at once, asserting the same two promises directly against
# a fresh MealLedger computation.
RSpec.describe Reconciliation do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def resident(multiplier: 2)
    create(:resident, community: community, unit: unit, multiplier: multiplier)
  end

  def settle
    described_class.create!(community: community, end_date: Date.yesterday).settlement_balances
  end

  it 'splits a prime number of cents across a prime number of eaters' do
    cook = resident
    eaters = Array.new(7) { resident(multiplier: 1) }

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('73.31'))
    eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 1) }
    meal.reload

    # 7331 cents is prime, so 7 eaters at multiplier 1 can never split it
    # evenly. Each exact share is 73.31 / 7 = 10.4728571... Truncating to
    # 10.47 collects only 73.29, so two pennies are left over. All seven
    # remainders tie, so the two eaters with the lowest ids pay 10.48.
    balances = settle

    expect(balances[cook.id]).to eq(BigDecimal('73.31'))
    expect(eaters.take(2).map { |e| balances[e.id] }).to all(eq(BigDecimal('-10.48')))
    expect(eaters.drop(2).map { |e| balances[e.id] }).to all(eq(BigDecimal('-10.47')))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'settles a one-cent bill: the lowest-id eater pays the penny, the others pay nothing' do
    cook = resident
    eaters = Array.new(3) { resident }

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0.01'))
    eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
    meal.reload

    # Each exact share is a third of a cent. All three truncate to zero, so
    # the whole cent is left over. The remainders tie, so the eater with
    # the lowest id pays it.
    balances = settle

    expect(balances[cook.id]).to eq(BigDecimal('0.01'))
    expect(balances[eaters[0].id]).to eq(BigDecimal('-0.01'))
    expect(balances[eaters[1].id]).to eq(BigDecimal('0'))
    expect(balances[eaters[2].id]).to eq(BigDecimal('0'))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'splits a half cent between two identical children by lowest resident_id' do
    cook = resident
    children = Array.new(2) { resident(multiplier: 1) }
    expect(children[0].id).to be < children[1].id

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('53.17'))
    children.each { |child| create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 1) }
    meal.reload

    # 53.17 across 2 units of multiplier is 26.585 per unit — an exact half
    # cent each, the worst case for rounding. Both truncate to 26.58,
    # leaving one penny; the remainders tie, so the lower id pays 26.59.
    balances = settle

    expect(balances[cook.id]).to eq(BigDecimal('53.17'))
    expect(balances[children[0].id]).to eq(BigDecimal('-26.59'))
    expect(balances[children[1].id]).to eq(BigDecimal('-26.58'))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'settles the largest awkward bill across a cook who eats, a guest, and a child' do
    cook = resident
    adult = resident
    child = resident(multiplier: 1)

    meal = create(:meal, community: community)
    # 9999.99, the maximum, is 142857 cents per unit across 7 units — an
    # exactly even split. One whole-cent step down, 9999.97, is not.
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('9999.97'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: adult, community: community)
    create(:guest, meal: meal, resident: adult, multiplier: 2)
    create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 1)
    meal.reload

    # Total multiplier is 7 (cook 2, adult 2, guest 2, child 1), so each
    # unit costs 9999.97 / 7 = 1428.5671428...
    #   cook:  9999.97 - 2 units = 7142.8357142... → truncates to  7142.83
    #   adult: -4 units (their guest's share is theirs)
    #                   = -5714.2685714... → truncates to -5714.26
    #   child: -1 unit  = -1428.5671428... → truncates to -1428.56
    # The truncated sum is +0.01, and the adult has the most negative
    # remainder, so the adult pays the extra penny.
    balances = settle

    expect(balances[cook.id]).to eq(BigDecimal('7142.83'))
    expect(balances[adult.id]).to eq(BigDecimal('-5714.27'))
    expect(balances[child.id]).to eq(BigDecimal('-1428.56'))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'settles one meal whose cost passes $10,000: two cooks at the bill maximum' do
    cook_a = resident
    cook_b = resident
    eater = resident(multiplier: 1)

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook_a, community: community, amount: BigDecimal('9999.99'))
    create(:bill, meal: meal, resident: cook_b, community: community, amount: BigDecimal('9999.99'))
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 1)
    meal.reload

    # A single bill is capped at $9,999.99, but a meal's cost is the sum of
    # its bills, so two cooks put the total at 19,999.98. With one unit of
    # multiplier, that whole amount is also the unit cost and the eater's
    # charge. Both used to overflow meal_charges' old DECIMAL(12,8) columns,
    # and the eater's settled balance overflowed the balance column the same
    # way — the one-meal half of the issue #60 regression test.
    balances = settle

    expect(balances[cook_a.id]).to eq(BigDecimal('9999.99'))
    expect(balances[cook_b.id]).to eq(BigDecimal('9999.99'))
    expect(balances[eater.id]).to eq(BigDecimal('-19999.98'))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))

    # The persisted charge lines carry the over-$10,000 amounts.
    debit = MealCharge.find_by(meal: meal, resident: eater)
    expect(debit.amount).to eq(BigDecimal('-19999.98'))
    expect(debit.unit_cost).to eq(BigDecimal('19999.98'))
  end

  it 'settles a cook who eats their own awkward bill alone at exactly zero' do
    cook = resident

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('53.17'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    meal.reload

    # The per-unit cost is 26.585 — a fractional cent — but the cook's
    # credit and debit are both built from the same amount, so they cancel
    # exactly and nothing is left to round.
    balances = settle

    expect(balances[cook.id]).to eq(BigDecimal('0'))
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'splits an awkward subsidy between cooks whose receipts are awkward too' do
    capped = create(:community, cap: BigDecimal('3.47'))
    capped_unit = create(:unit, community: capped)
    cook_a = create(:resident, community: capped, unit: capped_unit)
    cook_b = create(:resident, community: capped, unit: capped_unit)
    eaters = create_list(:resident, 3, community: capped, unit: capped_unit)

    meal = create(:meal, community: capped)
    create(:bill, meal: meal, resident: cook_a, community: capped, amount: BigDecimal('43.17'))
    create(:bill, meal: meal, resident: cook_b, community: capped, amount: BigDecimal('19.99'))
    eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: capped) }
    meal.reload

    # 6 units of multiplier at the 3.47 cap allows 20.82, against 63.16
    # spent, so the meal is subsidized and each cook is credited in
    # proportion to their receipt:
    #   cook_a: (43.17 / 63.16) × 20.82 = 14.2305161... → truncates to 14.23
    #   cook_b: (19.99 / 63.16) × 20.82 =  6.5894838... → truncates to  6.58
    #   eaters: 2 × 3.47 = 6.94 exactly, each
    # The truncated sum is -0.01, and cook_b has the most positive
    # remainder, so cook_b is credited the extra penny.
    balances = described_class.create!(community: capped, end_date: Date.yesterday).settlement_balances

    expect(balances[cook_a.id]).to eq(BigDecimal('14.23'))
    expect(balances[cook_b.id]).to eq(BigDecimal('6.59'))
    eaters.each { |eater| expect(balances[eater.id]).to eq(BigDecimal('-6.94')) }
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
  end

  it 'keeps every balance within one cent of exact, and the total at zero, across a batch of awkward meals' do
    cook = resident
    eaters = Array.new(5) { resident }

    # Cent counts that no small attendee count divides evenly, from one
    # cent up to the largest allowed bill. Attendee counts cycle 1..5 and
    # every third meal has a guest, so the batch mixes the shapes instead
    # of repeating one. The 9999.99 bill pushes the cook's settled balance
    # past $10,000, which used to overflow the old DECIMAL(12,8) balance
    # columns and crash the settlement — the regression test for issue #60.
    amounts = %w[0.01 0.03 0.97 5.03 9.73 12.37 33.31 53.17 73.31 99.73 997.03 9999.99]
    amounts.each_with_index do |amount, index|
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount))
      eaters.take((index % 5) + 1).each do |eater|
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
      create(:guest, meal: meal, resident: eaters.first, multiplier: 2) if (index % 3).zero?
    end

    reconciliation = described_class.create!(community: community, end_date: Date.yesterday)
    balances = reconciliation.settlement_balances

    meals = Meal.where(reconciliation: reconciliation).preload(:bills, :meal_residents, :guests).to_a
    exact = MealLedger.new(meals).balances(community.residents.pluck(:id))

    # The overflow regression only bites past $10,000, so make sure the
    # batch really gets the cook there.
    expect(balances[cook.id]).to be > BigDecimal('10_000')
    expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    balances.each do |resident_id, cents|
      # Within one cent of exact. The tolerance is a tiny amount more than
      # 0.01 only because a share that does not terminate (73.31 / 7)
      # leaves BigDecimal noise some twenty digits down.
      expect((cents - exact[resident_id]).abs).to be <= BigDecimal('0.0100000001')
    end
  end
end

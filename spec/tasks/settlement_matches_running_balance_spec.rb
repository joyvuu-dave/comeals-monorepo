# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require Rails.root.join('spec/support/oracle/plain_ledger')

# The number a resident watches all month (the running balance, from
# billing:recalculate) and the number they are finally billed (the settled
# balance, from Reconciliation#settlement_balances) must come from the same
# rules. A difference between them is the worst kind of money bug here:
# every individual number looks reasonable, both ledgers still sum to zero,
# and the only symptom is that a balance moves at settlement for no reason
# a resident can see.
#
# Both now run through MealLedger, so this spec checks them against a third
# party: the plain ledger (spec/support/oracle/plain_ledger.rb), written
# from the rules, told exactly which meals count.
#
# How the comparison works. The running balance is at the ledger grain; the
# settled balance is rounded to cents by largest-remainder allocation. So
# the two cannot be compared directly. Instead each example asserts:
#
#   - the running tie: the rake task's stored running balances equal the
#     plain ledger's, exactly. Every line is a whole number of 10^-8
#     dollars (ADR 0008), so what the task computes is what the DECIMAL(16,8)
#     column stores, and there is nothing to allow for;
#   - the exact tie: those running balances, put through the settlement's
#     own allocate_to_cents, equal the stored settled balances row for row;
#   - the loose tie: each stored settled balance is less than one cent
#     from the running balance, which is the guarantee largest-remainder
#     allocation actually makes.
RSpec.describe 'settlement and running-balance arithmetic agree', type: :task do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  after do
    Rake::Task['billing:recalculate'].reenable
  end

  # Computes every running balance, settles every eligible meal, and asserts
  # the two agree. Order matters: the rake task reads Meal.unreconciled, so
  # it must run before the settlement claims the meals.
  #
  # The settlement runs through settle! (spec/support/settle.rb), not the
  # :reconciliation factory. That factory's before(:create) hook builds its
  # own unit, cook, meal and bill, which would add a meal to the settlement
  # that neither running-balance path was asked about.
  #
  # The plain ledger is given every meal of the community: at this point
  # none is settled, so that is exactly what the running balance covers.
  def running_balances(community, residents)
    rows = community.meals.preload(:bills, :meal_residents, :guests)
    PlainLedger.balances(rows.map { |meal| RandomLedger.plain(meal) }, residents.map(&:id))
  end

  # The rake task's stored running balances equal the plain ledger's,
  # exactly, for every resident.
  def expect_running_tie(residents, stored_running, running)
    expect(residents.to_h { |r| [r.id, stored_running.fetch(r.id, BigDecimal('0'))] })
      .to eq(residents.to_h { |r| [r.id, running.fetch(r.id, BigDecimal('0'))] })
  end

  def expect_settlement_to_match_running_balances(community)
    residents = community.residents.order(:id).to_a
    running = running_balances(community, residents)

    Rake::Task['billing:recalculate'].reenable
    Rake::Task['billing:recalculate'].invoke
    stored_running = ResidentBalance.pluck(:resident_id, :amount).to_h
    expect_running_tie(residents, stored_running, running)

    reconciliation = settle!(cutoff: Date.yesterday)
    settled = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h

    # allocate_to_cents is private. Reaching past that is deliberate: the
    # point of this spec is that one copy of the arithmetic feeds the other
    # copy's rounding step, and any public stand-in would be a fourth copy.
    expected = Settlement.allocate_to_cents(running, reconciliation_id: reconciliation.id).reject do |_, amount|
      amount.zero?
    end

    expect(settled).to eq(expected)

    residents.each do |resident|
      settled_amount = settled.fetch(resident.id, BigDecimal('0'))
      running_amount = stored_running.fetch(resident.id, BigDecimal('0'))
      difference = (settled_amount - running_amount).abs

      expect(difference).to be < BigDecimal('0.01'),
                            "Resident #{resident.name}: settled #{settled_amount.to_s('F')} is " \
                            "#{difference.to_s('F')} from running #{running_amount.to_s('F')} — " \
                            'rounding to cents leaves a balance less than one cent from its lines.'
    end

    reconciliation
  end

  # cap is 4.50 per unit of multiplier. Meals below that are effectively
  # uncapped; meals above it are subsidized and exercise the proportional
  # credit branch. Setting it once here lets one community hold both kinds.
  let(:community) { create(:community, cap: BigDecimal('4.50')) }
  let(:unit) { create(:unit, community: community) }

  def resident(name, multiplier: 2)
    create(:resident, community: community, unit: unit, multiplier: multiplier, name: name)
  end

  it 'agrees on a plain meal with one cook and mixed multipliers' do
    cook = resident('Cook')
    adult = resident('Adult')
    child = resident('Child', multiplier: 1)

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: adult, community: community)
    create(:meal_resident, meal: meal, resident: child, community: community)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees on a subsidized meal where the cook spent more than the cap' do
    cook = resident('Cook')
    adult = resident('Adult')

    # 4 units of multiplier * 4.50 cap = 18.00 effective, against 60.00 spent.
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: adult, community: community)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees on a subsidized meal with two cooks, where credit is split proportionally' do
    cook_a = resident('Cook A')
    cook_b = resident('Cook B')
    adult = resident('Adult')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook_a, community: community, amount: BigDecimal('40'))
    create(:bill, meal: meal, resident: cook_b, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: meal, resident: cook_a, community: community)
    create(:meal_resident, meal: meal, resident: cook_b, community: community)
    create(:meal_resident, meal: meal, resident: adult, community: community)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees when one bill on the meal is marked no_cost' do
    cook = resident('Cook')
    helper = resident('Helper')
    adult = resident('Adult')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:bill, meal: meal, resident: helper, community: community, amount: BigDecimal('12'), no_cost: true)
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: helper, community: community)
    create(:meal_resident, meal: meal, resident: adult, community: community)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees when a resident brings guests' do
    cook = resident('Cook')
    host = resident('Host')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: host, community: community)
    create(:guest, meal: meal, resident: host, multiplier: 2)
    create(:guest, meal: meal, resident: host, multiplier: 1)

    expect_settlement_to_match_running_balances(community)
  end

  # Every line of a meal whose attendees all have multiplier zero is zero.
  # A settlement takes such a meal only when its cook slots hold no money;
  # one with money on a receipt is held back (#94), in the example below.
  it 'agrees on a meal whose attendees all have multiplier zero and whose cook spent nothing' do
    cook = resident('Cook')
    baby = resident('Baby', multiplier: 0)

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))
    create(:meal_resident, meal: meal, resident: baby, community: community)

    reconciliation = expect_settlement_to_match_running_balances(community)

    # Both paths give everyone zero, so nothing is stored. Asserted because
    # an empty table would also satisfy the comparison if both paths were
    # broken in the same way, and this is the branch where that is easiest.
    expect(reconciliation.meals).to contain_exactly(meal)
    expect(reconciliation.reconciliation_balances).to be_empty
  end

  it 'agrees when a receipt only free eaters ate is held back, where the cook absorbs the cost' do
    cook = resident('Cook')
    eater = resident('Eater')
    baby = resident('Baby', multiplier: 0)
    held = create(:meal, community: community, date: Date.yesterday - 1)
    create(:bill, meal: held, resident: cook, community: community, amount: BigDecimal('25'))
    create(:meal_resident, meal: held, resident: baby, community: community)
    eaten = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: eaten, resident: cook, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: eaten, resident: eater, community: community)

    reconciliation = expect_settlement_to_match_running_balances(community)

    # The running balance counts the held meal, because someone ate, but
    # every one of its lines is zero: the cook absorbs the $25 there. The
    # settlement does not sweep it, so it adds nothing there either.
    expect(held.reload.reconciliation_id).to be_nil
    expect(reconciliation.meals).to contain_exactly(eaten)
  end

  it 'agrees when a receipt nobody ate is held back' do
    cook = resident('Cook')
    eater = resident('Eater')
    held = create(:meal, community: community, date: Date.yesterday - 1)
    create(:bill, meal: held, resident: cook, community: community, amount: BigDecimal('25'))
    eaten = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: eaten, resident: cook, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: eaten, resident: eater, community: community)

    reconciliation = expect_settlement_to_match_running_balances(community)

    # The held meal is in neither computation: no eater, so no lines in the
    # running balance, and not swept, so no lines in the settlement.
    expect(held.reload.reconciliation_id).to be_nil
    expect(reconciliation.meals).to contain_exactly(eaten)
  end

  it 'agrees across many meals at once, where residents both cook and eat' do
    cook_a = resident('Cook A')
    cook_b = resident('Cook B')
    adult = resident('Adult')
    child = resident('Child', multiplier: 1)
    baby = resident('Baby', multiplier: 0)
    host = resident('Host')
    everyone = [cook_a, cook_b, adult, child, baby, host]

    # Amounts chosen to divide badly, so the raw balances carry long
    # fractions and largest-remainder allocation has real residual pennies
    # to hand out. That is the part most likely to expose a difference.
    [
      { cook: cook_a, amount: BigDecimal('50'), eaters: everyone, guests: 0 },
      { cook: cook_b, amount: BigDecimal('73.19'), eaters: [cook_b, adult, child], guests: 1 },
      { cook: adult, amount: BigDecimal('11.03'), eaters: [adult, host, baby], guests: 0 },
      { cook: cook_a, amount: BigDecimal('120.55'), eaters: everyone, guests: 2 },
      { cook: host, amount: BigDecimal('9.99'), eaters: [host, cook_a], guests: 0 }
    ].each do |spec|
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: spec[:cook], community: community, amount: spec[:amount])
      spec[:eaters].each do |eater|
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
      spec[:guests].times { create(:guest, meal: meal, resident: host, multiplier: 2) }
    end

    reconciliation = expect_settlement_to_match_running_balances(community)

    # Guard against the whole example passing vacuously: if every balance
    # were zero, the comparison above would hold no matter what the
    # arithmetic did.
    expect(reconciliation.reconciliation_balances.count).to be >= 4
    expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(BigDecimal('0'))
  end
end

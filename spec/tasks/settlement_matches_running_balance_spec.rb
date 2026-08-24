# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The same money arithmetic is written three times in this app:
#
#   1. Reconciliation#settlement_balances — what a resident finally owes.
#   2. lib/tasks/billing/recalculate.rake — the running balance, over
#      unreconciled meals.
#   3. Resident#calc_balance and its helpers — a per-resident version kept
#      as an oracle, not used in production.
#
# Copies 2 and 3 are already checked against each other by
# spec/tasks/billing_recalculate_correctness_spec.rb. Copy 1 was checked
# against neither. So nothing said that the number a resident watches all
# month and the number they are finally billed come from the same rules.
# A difference between them is the worst kind of money bug here: every
# individual number looks reasonable, both ledgers still sum to zero, and
# the only symptom is that a balance moves at settlement for no reason a
# resident can see.
#
# This spec closes that gap. It is a characterization spec: it does not say
# what the arithmetic should be, only that all three copies say the same
# thing. That makes it the safety net for merging them into one
# implementation — see docs/money-path-observability.md.
#
# How the comparison works. The running balance is full precision; the
# settled balance is rounded to cents by largest-remainder allocation. So
# the two cannot be compared directly. Instead each example asserts:
#
#   - the exact tie: running balances, put through the settlement's own
#     allocate_to_cents, equal the stored settled balances row for row;
#   - the loose tie: each stored settled balance is within one cent of the
#     rake task's stored running balance, which is the guarantee
#     largest-remainder allocation actually makes.
#
# The exact tie runs against Resident#calc_balance rather than the rake
# task's output. Both express the running math, but resident_balances.amount
# is DECIMAL(16,8), and truncating there could in principle change which
# resident wins a residual penny. calc_balance returns the untruncated
# BigDecimal, so the exact assertion has no rounding in its path.
RSpec.describe 'settlement and running-balance arithmetic agree', type: :task do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  after do
    Rake::Task['billing:recalculate'].reenable
  end

  # Computes every running balance, settles every eligible meal, and asserts
  # the two agree. Order matters: both running-balance paths read
  # Meal.unreconciled, so they must run before the reconciliation claims the
  # meals.
  #
  # Reconciliation.create! is used directly rather than the :reconciliation
  # factory. That factory's before(:create) hook builds its own unit, cook,
  # meal and bill, which would add a meal to the settlement that neither
  # running-balance path was asked about.
  def expect_settlement_to_match_running_balances(community)
    residents = community.residents.order(:id).to_a
    running = residents.index_by(&:id).transform_values(&:calc_balance)

    Rake::Task['billing:recalculate'].reenable
    Rake::Task['billing:recalculate'].invoke
    stored_running = ResidentBalance.pluck(:resident_id, :amount).to_h

    reconciliation = settle!(community, cutoff: Date.yesterday)
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

      expect(difference).to be <= BigDecimal('0.01'),
                            "Resident #{resident.name}: settled #{settled_amount.to_s('F')} is " \
                            "#{difference.to_s('F')} from running #{running_amount.to_s('F')} — " \
                            'largest-remainder allocation may only move a balance by one cent.'
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
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: adult, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 1)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees on a subsidized meal where the cook spent more than the cap' do
    cook = resident('Cook')
    adult = resident('Adult')

    # 4 units of multiplier * 4.50 cap = 18.00 effective, against 60.00 spent.
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: adult, community: community, multiplier: 2)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees on a subsidized meal with two cooks, where credit is split proportionally' do
    cook_a = resident('Cook A')
    cook_b = resident('Cook B')
    adult = resident('Adult')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook_a, community: community, amount: BigDecimal('40'))
    create(:bill, meal: meal, resident: cook_b, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: meal, resident: cook_a, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: cook_b, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: adult, community: community, multiplier: 2)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees when one bill on the meal is marked no_cost' do
    cook = resident('Cook')
    helper = resident('Helper')
    adult = resident('Adult')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:bill, meal: meal, resident: helper, community: community, amount: BigDecimal('12'), no_cost: true)
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: helper, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: adult, community: community, multiplier: 2)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees when a resident brings guests' do
    cook = resident('Cook')
    host = resident('Host')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: host, community: community, multiplier: 2)
    create(:guest, meal: meal, resident: host, multiplier: 2)
    create(:guest, meal: meal, resident: host, multiplier: 1)

    expect_settlement_to_match_running_balances(community)
  end

  it 'agrees on a meal whose attendees all have multiplier zero, where the cook absorbs the cost' do
    cook = resident('Cook')
    baby = resident('Baby', multiplier: 0)

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
    create(:meal_resident, meal: meal, resident: baby, community: community, multiplier: 0)

    reconciliation = expect_settlement_to_match_running_balances(community)

    # Both paths give everyone zero, so nothing is stored. Asserted because
    # an empty table would also satisfy the comparison if both paths were
    # broken in the same way, and this is the branch where that is easiest.
    expect(reconciliation.reconciliation_balances).to be_empty
    expect(cook.reload.calc_balance).to eq(BigDecimal('0'))
  end

  it 'agrees on a meal that has a bill but nobody attending' do
    cook = resident('Cook')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))

    reconciliation = expect_settlement_to_match_running_balances(community)

    # The meal is swept — it has a bill — but with_attendees drops it from
    # both computations, so it moves no money.
    expect(meal.reload.reconciliation_id).to eq(reconciliation.id)
    expect(reconciliation.reconciliation_balances).to be_empty
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
        create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: eater.multiplier)
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

# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Verifies the production billing:recalculate batch math against the
# per-resident Resident#calc_balance oracle. The two implementations must
# stay in sync (see the DERIVED DATA comment in app/models/resident.rb).
#
# The deterministic dataset runs in every rspec invocation and covers the
# money edge cases CLAUDE.md mandates: capped/subsidized meals, multi-cook
# meals, no_cost bills, guests, and child-only (zero-multiplier) meals.
# The large randomized dataset is :benchmark-tagged and excluded from normal
# runs (see rails_helper.rb); run it with BENCHMARK=1.
RSpec.describe 'billing:recalculate correctness', type: :task do
  before(:all) do
    Rails.application.load_tasks
  end

  after do
    Rake::Task['billing:recalculate'].reenable
  end

  # Run the rake task and verify each resident's cached balance matches the
  # calc_balance oracle. Oracle balances must be computed BEFORE invoking the
  # task only in the sense of correctness comparison — calc_balance reads
  # source records, not resident_balances, so order does not matter; we
  # compute them first anyway so a task crash still shows oracle values.
  # Compares at DECIMAL(12,8) precision since that's what the DB stores.
  def expect_cached_balances_to_match_oracle(residents)
    expected = {}
    residents.each { |resident| expected[resident.id] = resident.calc_balance }

    Rake::Task['billing:recalculate'].reenable
    Rake::Task['billing:recalculate'].invoke

    residents.each do |resident|
      cached = ResidentBalance.find_by(resident_id: resident.id)&.amount || BigDecimal('0')
      expect(cached.round(8)).to eq(expected[resident.id].round(8)),
                                 "Resident #{resident.name}: " \
                                 "expected #{expected[resident.id].round(8)}, " \
                                 "got #{cached.round(8)}"
    end

    expected
  end

  it 'matches the oracle and hand-computed balances on a deterministic dataset ' \
     'covering capped, multi-cook, no_cost, guest, and child-only meals' do
    community = create(:community, cap: BigDecimal('4.50'))
    unit = create(:unit, community: community)

    cook_a = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook A')
    cook_b = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook B')
    adult = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Adult')
    child = create(:resident, community: community, unit: unit, multiplier: 1, name: 'Child')
    baby = create(:resident, community: community, unit: unit, multiplier: 0, name: 'Baby')
    host = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Host')
    residents = [cook_a, cook_b, adult, child, baby, host]

    # Meal 1 — capped, subsidized, multi-cook, with a guest.
    # total_mult = adult(2) + child(1) + host(2) + guest(2) = 7
    # max_cost = 4.50 * 7 = 31.50; total_cost = 24 + 16 = 40 > 31.50 → subsidized
    # unit_cost = 31.50 / 7 = 4.50
    # credits: cook_a (24/40)*31.50 = 18.90, cook_b (16/40)*31.50 = 12.60
    # debits: adult 9, child 4.50, host 9 + 9 (guest) = 18
    meal1 = create(:meal, community: community)
    create(:meal_resident, meal: meal1, resident: adult, community: community)
    create(:meal_resident, meal: meal1, resident: child, community: community)
    create(:meal_resident, meal: meal1, resident: host, community: community)
    create(:guest, meal: meal1, resident: host, multiplier: 2)
    create(:bill, meal: meal1, resident: cook_a, community: community, amount: BigDecimal('24'))
    create(:bill, meal: meal1, resident: cook_b, community: community, amount: BigDecimal('16'))

    # Meal 2 — capped but under the cap: full reimbursement.
    # total_mult = adult(2) + child(1) = 3; max_cost = 13.50; total_cost = 9
    # unit_cost = 3; credits: cook_a 9; debits: adult 6, child 3
    meal2 = create(:meal, community: community)
    create(:meal_resident, meal: meal2, resident: adult, community: community)
    create(:meal_resident, meal: meal2, resident: child, community: community)
    create(:bill, meal: meal2, resident: cook_a, community: community, amount: BigDecimal('9'))

    # Meal 3 — uncapped, with a no_cost bill alongside a real one.
    # total_cost = 30 (no_cost excluded); unit_cost = 30 / 4 = 7.50
    # credits: cook_b 30, cook_a 0; debits: adult 15, host 15
    meal3 = create(:meal, community: community)
    meal3.update!(cap: nil)
    create(:meal_resident, meal: meal3, resident: adult, community: community)
    create(:meal_resident, meal: meal3, resident: host, community: community)
    create(:bill, meal: meal3, resident: cook_b, community: community, amount: BigDecimal('30'))
    create(:bill, meal: meal3, resident: cook_a, community: community, amount: BigDecimal('10'),
                  no_cost: true)

    # Meal 4 — uncapped child-only meal (zero total multiplier).
    # Nobody can be charged a share → the meal is zeroed and cook_a absorbs
    # the cost. This is the case where the oracle historically diverged
    # (credited the full bill with no offsetting debit).
    meal4 = create(:meal, community: community)
    meal4.update!(cap: nil)
    create(:meal_resident, meal: meal4, resident: baby, community: community)
    create(:bill, meal: meal4, resident: cook_a, community: community, amount: BigDecimal('25'))

    # Meal 5 — only no_cost bills: total_cost = 0, nothing credited or charged.
    meal5 = create(:meal, community: community)
    create(:meal_resident, meal: meal5, resident: adult, community: community)
    create(:bill, meal: meal5, resident: cook_b, community: community, amount: BigDecimal('12'),
                  no_cost: true)

    expected = expect_cached_balances_to_match_oracle(residents)

    # Triple-entry check: both implementations must also match the hand-
    # computed balances, so a bug edited into BOTH paths "in sync" still fails.
    hand_computed = {
      cook_a.id => BigDecimal('27.90'),  # 18.90 + 9
      cook_b.id => BigDecimal('42.60'),  # 12.60 + 30
      adult.id => BigDecimal('-30'),     # -9 - 6 - 15
      child.id => BigDecimal('-7.50'),   # -4.50 - 3
      baby.id => BigDecimal('0'),
      host.id => BigDecimal('-33')       # -18 - 15
    }
    hand_computed.each do |resident_id, amount|
      expect(expected[resident_id].round(8)).to eq(amount)
    end

    # Books balance: credits equal debits across the whole dataset.
    expect(expected.values.sum(BigDecimal('0')).abs).to be < BigDecimal('0.00000001')
  end

  describe 'randomized large dataset', :benchmark do
    it 'optimized rake task produces same results as per-resident calc_balance' do
      srand(42)

      # Build a community with varied meal data
      community = create(:community, cap: BigDecimal('4.50'))
      unit = create(:unit, community: community)

      residents = Array.new(10) do |i|
        create(:resident, community: community, unit: unit, multiplier: i < 7 ? 2 : 1)
      end

      # Create 20 meals with varied properties
      now = Time.current
      start_date = Date.new(2025, 6, 1)
      meal_rows = Array.new(20) do |i|
        date = start_date + i.days
        {
          community_id: community.id,
          date: date,
          description: '',
          closed: false,
          cap: i % 3 == 0 ? nil : community.cap,
          start_time: date.to_datetime + 19.hours,
          created_at: now,
          updated_at: now
        }
      end
      Meal.insert_all(meal_rows)
      meals = Meal.where(community_id: community.id).order(:date).to_a

      # Bills (1-2 per meal, some no_cost)
      bill_rows = meals.flat_map do |meal|
        cook_count = rand(1..2)
        residents.sample(cook_count).map do |cook|
          {
            meal_id: meal.id,
            resident_id: cook.id,
            community_id: community.id,
            amount: BigDecimal(rand(15.0..60.0).round(2).to_s),
            no_cost: rand(100) < 10,
            created_at: now,
            updated_at: now
          }
        end
      end
      Bill.insert_all(bill_rows)

      # Meal residents (5-8 per meal)
      mr_rows = meals.flat_map do |meal|
        residents.sample(rand(5..8)).map do |resident|
          {
            meal_id: meal.id,
            resident_id: resident.id,
            community_id: community.id,
            multiplier: resident.multiplier,
            vegetarian: false,
            late: false,
            created_at: now,
            updated_at: now
          }
        end
      end
      MealResident.insert_all(mr_rows)

      # Guests (1-3 per meal)
      guest_rows = meals.flat_map do |meal|
        residents.sample(rand(1..3)).map do |resident_host|
          {
            meal_id: meal.id,
            resident_id: resident_host.id,
            multiplier: 2,
            vegetarian: false,
            late: false,
            created_at: now,
            updated_at: now
          }
        end
      end
      Guest.insert_all(guest_rows)

      expect_cached_balances_to_match_oracle(residents)
    end
  end
end

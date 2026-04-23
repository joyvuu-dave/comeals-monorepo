# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'billing:recalculate' do
  before(:all) do
    Rails.application.load_tasks
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  after do
    Rake::Task['billing:recalculate'].reenable
  end

  it 'computes and stores resident balances from source data' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community)

    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    meal.reload

    Rake::Task['billing:recalculate'].invoke

    cook_balance = ResidentBalance.find_by(resident: cook)
    eater_balance = ResidentBalance.find_by(resident: eater)

    expect(cook_balance).to be_present
    expect(cook_balance.amount).to eq(BigDecimal('60'))

    expect(eater_balance).to be_present
    expect(eater_balance.amount).to eq(BigDecimal('-60'))
  end

  it 'excludes reconciled meals from balance calculations' do
    reconciliation = Reconciliation.create!(community: community, end_date: Time.zone.today)
    resident = create(:resident, community: community, unit: unit, multiplier: 2)

    # Reconciled meal with big bill — should NOT affect balance. Build the
    # bill first, then set reconciliation_id via update_columns; Bill's
    # before_save now rejects any save when meal.reconciled?.
    reconciled_meal = create(:meal, community: community)
    create(:bill, meal: reconciled_meal, resident: resident, community: community, amount: BigDecimal('500'))
    reconciled_meal.update_columns(reconciliation_id: reconciliation.id)

    # Unreconciled meal — cook and attend = 0 balance
    unreconciled_meal = create(:meal, community: community)
    create(:meal_resident, meal: unreconciled_meal, resident: resident, community: community)
    create(:bill, meal: unreconciled_meal, resident: resident, community: community,
                  amount: BigDecimal('30'))

    Rake::Task['billing:recalculate'].invoke

    balance = ResidentBalance.find_by(resident: resident)
    expect(balance.amount).to eq(BigDecimal('0'))
  end

  it 'handles residents with no meals gracefully' do
    resident = create(:resident, community: community, unit: unit)

    Rake::Task['billing:recalculate'].invoke

    balance = ResidentBalance.find_by(resident: resident)
    expect(balance).to be_present
    expect(balance.amount).to eq(BigDecimal('0'))
  end

  it 'is idempotent — running twice produces the same result' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community)

    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
    meal.reload

    Rake::Task['billing:recalculate'].invoke
    first_run_cook = ResidentBalance.find_by(resident: cook).amount
    first_run_eater = ResidentBalance.find_by(resident: eater).amount

    Rake::Task['billing:recalculate'].reenable
    Rake::Task['billing:recalculate'].invoke

    expect(ResidentBalance.find_by(resident: cook).amount).to eq(first_run_cook)
    expect(ResidentBalance.find_by(resident: eater).amount).to eq(first_run_eater)
    # Still exactly one record per resident (upsert, not insert)
    expect(ResidentBalance.where(resident: cook).count).to eq(1)
    expect(ResidentBalance.where(resident: eater).count).to eq(1)
  end
end

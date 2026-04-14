# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin Reconciliation Update Meals' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def update_meals(reconciliation, meal_ids:)
    patch "/reconciliations/#{reconciliation.id}/update_meals",
          params: { meal_ids: meal_ids }
  end

  it 'removes a meal by submitting a list that excludes it' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)

    meal_to_remove = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:meal_resident, meal: meal_to_remove, resident: eater, community: community)
    create(:bill, meal: meal_to_remove, resident: cook, community: community, amount: BigDecimal('40'))

    meal_to_keep = create(:meal, community: community, date: Date.new(2025, 3, 2))
    create(:meal_resident, meal: meal_to_keep, resident: eater, community: community)
    create(:bill, meal: meal_to_keep, resident: cook, community: community, amount: BigDecimal('60'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))

    expect(reconciliation.balance_for(cook)).to eq(BigDecimal('100'))

    # Submit list excluding meal_to_remove
    update_meals(reconciliation, meal_ids: [meal_to_keep.id])

    expect(response).to redirect_to("/reconciliations/#{reconciliation.id}")
    expect(meal_to_remove.reload.reconciliation_id).to be_nil
    expect(meal_to_keep.reload.reconciliation_id).to eq(reconciliation.id)
    expect(reconciliation.balance_for(cook)).to eq(BigDecimal('60'))
    expect(reconciliation.balance_for(eater)).to eq(BigDecimal('-60'))
  end

  it 'adds an unreconciled meal by including it in the submitted list' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)

    in_meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:meal_resident, meal: in_meal, resident: eater, community: community)
    create(:bill, meal: in_meal, resident: cook, community: community, amount: BigDecimal('40'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))
    expect(in_meal.reload.reconciliation_id).to eq(reconciliation.id)

    # Create an unreconciled meal eligible to be added (date <= end_date)
    out_meal = create(:meal, community: community, date: Date.new(2025, 3, 15))
    create(:meal_resident, meal: out_meal, resident: eater, community: community)
    create(:bill, meal: out_meal, resident: cook, community: community, amount: BigDecimal('20'))
    out_meal.update!(reconciliation_id: nil) # Force unreconciled state

    update_meals(reconciliation, meal_ids: [in_meal.id, out_meal.id])

    expect(response).to redirect_to("/reconciliations/#{reconciliation.id}")
    expect(out_meal.reload.reconciliation_id).to eq(reconciliation.id)
    expect(reconciliation.balance_for(cook)).to eq(BigDecimal('60'))
  end

  it 'handles add and remove in a single submission' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)

    meal_a = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:meal_resident, meal: meal_a, resident: eater, community: community)
    create(:bill, meal: meal_a, resident: cook, community: community, amount: BigDecimal('40'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))

    meal_b = create(:meal, community: community, date: Date.new(2025, 3, 5))
    create(:meal_resident, meal: meal_b, resident: eater, community: community)
    create(:bill, meal: meal_b, resident: cook, community: community, amount: BigDecimal('80'))
    meal_b.update!(reconciliation_id: nil)

    # Swap: remove meal_a, add meal_b
    update_meals(reconciliation, meal_ids: [meal_b.id])

    expect(meal_a.reload.reconciliation_id).to be_nil
    expect(meal_b.reload.reconciliation_id).to eq(reconciliation.id)
    expect(reconciliation.balance_for(cook)).to eq(BigDecimal('80'))
  end

  it 'rejects adding a meal from another reconciliation' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)

    meal_in_other = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal_in_other, resident: cook, community: community, amount: BigDecimal('40'))

    other_recon = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))
    expect(meal_in_other.reload.reconciliation_id).to eq(other_recon.id)

    # New empty reconciliation
    target = Reconciliation.create!(community: community, end_date: Date.new(2025, 4, 30))

    # Attempt to claim a meal that's already in another reconciliation
    update_meals(target, meal_ids: [meal_in_other.id])

    expect(response).to redirect_to("/reconciliations/#{target.id}")
    expect(flash[:alert]).to match(/not eligible/)
    expect(meal_in_other.reload.reconciliation_id).to eq(other_recon.id)
  end

  it 'rejects adding a meal with date after end_date' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))

    too_late = create(:meal, community: community, date: Date.new(2025, 4, 15))
    create(:bill, meal: too_late, resident: cook, community: community, amount: BigDecimal('40'))

    update_meals(reconciliation, meal_ids: [too_late.id])

    expect(flash[:alert]).to match(/not eligible/)
    expect(too_late.reload.reconciliation_id).to be_nil
  end

  it 'handles an empty submission by removing all meals' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)

    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))
    expect(reconciliation.meals.count).to eq(1)

    patch "/reconciliations/#{reconciliation.id}/update_meals" # no params

    expect(meal.reload.reconciliation_id).to be_nil
    expect(reconciliation.reload.meals.count).to eq(0)
    expect(reconciliation.balance_for(cook)).to eq(BigDecimal('0'))
  end
end

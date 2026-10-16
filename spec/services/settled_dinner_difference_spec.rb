# frozen_string_literal: true

require 'rails_helper'

# Whether a settled dinner's rows still add up to what it was settled at
# plus its corrections (ADR 0011 rule 6). The nightly check and
# MealCorrecting read the answer; their specs check what each does with
# it. These check the answer itself: which people differ, and the two
# amounts for each.
#
# Each example asks about two dinners. The second one never changes, and
# a person who agrees is never in the answer.
RSpec.describe SettledDinnerDifference do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:first_eater) { create(:resident, community: community, unit: unit, name: 'First Eater') }
  let(:second_eater) { create(:resident, community: community, unit: unit, name: 'Second Eater') }

  # $30. The cook also eats, so the cook has two lines: credited $30 and
  # charged $15. The first eater is charged $15.
  let!(:meal) do
    create(:meal, community: community, date: latest - 5).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      [cook, first_eater].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    end
  end
  let!(:untouched) do
    create(:meal, community: community, date: latest - 6).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: meal, resident: first_eater, community: community)
    end
  end

  before { settle!(cutoff: latest - 5) }

  def difference
    described_class.for(Meal.where(id: [meal.id, untouched.id]).preload(:bills, :meal_residents, :guests).to_a)
  end

  def add_eater_with_a_correction(eater)
    MealCorrecting.save!(meal.reload, by: admin, reason: 'Ate and was missed') { |edits| edits.add_eater(eater) }
  end

  # Writes that skip the correction: psql with the repair bypass.
  def sign_up_without_a_correction(eater)
    with_repair_bypass do
      MealResident.insert!({ meal_id: meal.id, resident_id: eater.id, community_id: community.id, multiplier: 2 })
    end
  end

  def remove_without_a_correction(eater)
    with_repair_bypass { MealResident.where(meal_id: meal.id, resident_id: eater.id).delete_all }
  end

  def amounts(settled_plus_corrections, rows_now)
    [BigDecimal(settled_plus_corrections), BigDecimal(rows_now)]
  end

  it 'agrees with dinners whose rows have not changed, the cook\'s two lines added up' do
    expect(difference).to eq({})
  end

  # After: $30 over three eaters of two units each. The cook nets $20,
  # and each eater is charged $10. The second eater was not settled: only
  # the correction and the rows name them.
  it 'agrees with a dinner changed only by a correction, for a person the correction added too' do
    add_eater_with_a_correction(second_eater)

    expect(difference).to eq({})
  end

  it 'names each person when a sign-up was added without a correction' do
    sign_up_without_a_correction(second_eater)

    expect(difference).to eq(meal.id => { cook.id => amounts('15', '20'), first_eater.id => amounts('-15', '-10'),
                                          second_eater.id => amounts('0', '-10') })
  end

  # The first eater has no line now, so is charged $0. The cook eats
  # alone: credited $30 and charged $30.
  it 'names a person whose sign-up was removed without a correction, as charged nothing now' do
    remove_without_a_correction(first_eater)

    expect(difference).to eq(meal.id => { cook.id => amounts('15', '0'), first_eater.id => amounts('-15', '0') })
  end

  # The correction added the second eater, at -$10 for them and +$5 each
  # for the other two. Then the sign-up went without a correction, so the
  # rows are back to what was settled.
  it 'names a person a correction added, when their sign-up was later removed without one' do
    add_eater_with_a_correction(second_eater)
    remove_without_a_correction(second_eater)

    expect(difference).to eq(meal.id => { cook.id => amounts('20', '15'), first_eater.id => amounts('-10', '-15'),
                                          second_eater.id => amounts('-10', '0') })
  end
end

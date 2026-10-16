# frozen_string_literal: true

require 'rails_helper'

# == Schema Information
#
# Table name: meal_corrections
#
#  id                :bigint           not null, primary key
#  edits             :jsonb            not null
#  reason            :text             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  admin_user_id     :bigint           not null
#  meal_id           :bigint           not null
#  reconciliation_id :bigint
#
# Indexes
#
#  index_meal_corrections_on_admin_user_id      (admin_user_id)
#  index_meal_corrections_on_meal_id            (meal_id)
#  index_meal_corrections_on_reconciliation_id  (reconciliation_id)
#
# Foreign Keys
#
#  fk_rails_...  (admin_user_id => admin_users.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#
# The record of a correction to a settled dinner (ADR 0011 rule 6). It is
# written by MealCorrecting (meal_correcting_spec.rb); this is the record
# itself: what it requires, which ones wait for a settlement, and that it
# never changes. The database's rules are in
# spec/db/meal_corrections_triggers_spec.rb.
RSpec.describe MealCorrection do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:meal) do
    create(:meal, community: community, date: latest - 3).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                             community: community)
      settle!(cutoff: latest - 3)
    end.reload
  end

  def correct(reason = 'Typed $30 for $20', amount: '20')
    MealCorrecting.save!(meal, by: admin, reason: reason) do |edits|
      edits.cost(cook, amount: BigDecimal(amount), no_cost: false)
    end
  end

  it 'needs a reason' do
    correction = described_class.new(meal: meal, admin_user: admin, reason: '')

    expect(correction).not_to be_valid
    expect(correction.errors[:reason]).to eq(["can't be blank"])
  end

  it 'waits for a settlement until one carries it' do
    first = correct
    expect(described_class.waiting).to eq([first])

    settle!(cutoff: latest)
    second = correct('And again', amount: '21')
    expect(described_class.waiting).to eq([second])
  end

  it 'cannot be changed or destroyed, and says why' do
    correction = correct

    expect(correction.update(reason: 'Another')).to be(false)
    expect(correction.errors[:base]).to eq(['A correction is a record of what changed on a settled dinner, and ' \
                                            'cannot be modified.'])
    expect(correction.destroy).to be(false)
    expect(correction.errors[:base]).to include('A correction is a record of what changed on a settled dinner, ' \
                                                'and cannot be destroyed.')
  end

  # The cook mail lists the edits to that cook's own cost
  # (ReconciliationMailer): not the cook's sign-up, and not another cook's
  # cost.
  it 'gives one resident\'s cost edits, and none of their other edits' do
    helper = create(:resident, community: community, unit: unit)
    correction = MealCorrecting.save!(meal, by: admin, reason: 'The cook ate, and a helper cooked') do |edits|
      edits.add_eater(cook)
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
      edits.cost(helper, amount: BigDecimal('5'), no_cost: false)
    end

    expect(correction.cost_edits_of(cook)).to eq([{ 'what' => 'cost', 'resident_id' => cook.id,
                                                    'from' => { 'amount' => '30.0', 'no_cost' => false },
                                                    'to' => { 'amount' => '20.0', 'no_cost' => false } }])
    expect(correction.cost_edits_of(helper).pluck('resident_id')).to eq([helper.id])
  end

  describe MealCorrectionLine do
    it 'cannot be changed or destroyed, is never zero, and is one a person' do
      line = correct.lines.first

      expect(line.update(amount: BigDecimal('1'))).to be(false)
      expect(line.destroy).to be(false)
      expect(described_class.new(meal_correction: line.meal_correction, resident: line.resident,
                                 amount: BigDecimal('0'))).not_to be_valid
      duplicate = described_class.new(meal_correction: line.meal_correction, resident: line.resident,
                                      amount: BigDecimal('1'))
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:resident_id]).to eq(['has already been taken'])
    end
  end
end

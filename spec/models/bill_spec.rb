# frozen_string_literal: true

# == Schema Information
#
# Table name: bills
#
#  id           :bigint           not null, primary key
#  amount       :decimal(12, 8)   default(0.0), not null
#  no_cost      :boolean          default(FALSE), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  meal_id      :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_bills_on_meal_id                  (meal_id)
#  index_bills_on_meal_id_and_resident_id  (meal_id,resident_id) UNIQUE
#  index_bills_on_resident_id              (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#
require 'rails_helper'

RSpec.describe Bill do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe 'validations' do
    it 'rejects negative amounts' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = build(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('-1'))

      expect(bill).not_to be_valid
      expect(bill.errors[:amount]).to be_present
    end

    it 'rejects sub-cent amounts' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = build(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('12.345'))

      expect(bill).not_to be_valid
      expect(bill.errors[:amount]).to include('must be whole cents')
    end

    it 'rejects amounts over 9999.99' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = build(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('10000'))

      expect(bill).not_to be_valid
      expect(bill.errors[:amount]).to be_present
    end

    it 'accepts whole-cent amounts' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = build(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('9999.99'))

      expect(bill).to be_valid
    end

    it 'enforces one bill per resident per meal' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: resident, community: community)

      duplicate = build(:bill, meal: meal, resident: resident, community: community)
      expect(duplicate).not_to be_valid
    end
  end

  describe '#set_community_id' do
    it 'copies community_id from the meal before validation' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = described_class.new(meal: meal, resident: resident, amount: BigDecimal('10'))

      bill.valid?
      expect(bill.community_id).to eq(community.id)
    end
  end

  describe '#reconciled?' do
    it 'returns true when the meal is reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community)
      # Reconciliation must happen AFTER bill creation — before_save :reject_if_reconciled
      # blocks creating bills on an already-reconciled meal.
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect(bill.reload.reconciled?).to be true
    end

    it 'returns false when the meal is not reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community)

      expect(bill.reconciled?).to be false
    end
  end

  describe '#destroy' do
    it 'blocks destruction when meal is reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect { bill.destroy }.not_to change(described_class, :count)
      expect(bill.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'allows destruction when meal is not reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community)

      expect { bill.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe '#save (reconciled immutability)' do
    it 'blocks updating amount when meal is reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      meal.update!(reconciliation: create(:reconciliation, community: community))

      bill.amount = BigDecimal('999')
      expect(bill.save).to be false
      expect(bill.errors[:base]).to include('Meal has been reconciled.')
      expect(bill.reload.amount).to eq(BigDecimal('50'))
    end

    it 'blocks toggling no_cost when meal is reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community, no_cost: false)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      bill.no_cost = true
      expect(bill.save).to be false
      expect(bill.reload.no_cost).to be false
    end

    it 'blocks creating a new bill on a reconciled meal' do
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community, reconciliation: reconciliation)
      resident = create(:resident, community: community, unit: unit)

      bill = build(:bill, meal: meal, resident: resident, community: community)
      expect(bill.save).to be false
      expect(bill.errors[:base]).to include('Meal has been reconciled.')
    end

    it 'allows updates when meal is not reconciled' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      bill.amount = BigDecimal('75')
      expect(bill.save).to be true
      expect(bill.reload.amount).to eq(BigDecimal('75'))
    end

    it 'blocks re-parenting a bill out of a reconciled meal' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      meal.update!(reconciliation: create(:reconciliation, community: community))
      unreconciled_meal = create(:meal, community: community)

      # The meal association now points at the NEW (unreconciled) meal — the
      # guard must still see that the OLD meal's ledger is closed.
      bill.meal = unreconciled_meal
      expect(bill.save).to be false
      expect(bill.errors[:base]).to include('Meal has been reconciled.')
      expect(bill.reload.meal_id).to eq(meal.id)
    end

    it 'blocks re-parenting a bill onto a reconciled meal' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      reconciled_meal = create(:meal, community: community)
      reconciled_meal.update!(reconciliation: create(:reconciliation, community: community))

      bill.meal = reconciled_meal
      expect(bill.save).to be false
      expect(bill.errors[:base]).to include('Meal has been reconciled.')
      expect(bill.reload.meal_id).to eq(meal.id)
    end
  end
end

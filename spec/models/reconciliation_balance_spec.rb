# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliation_balances
#
#  id                :bigint           not null, primary key
#  amount            :decimal(16, 8)   default(0.0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  reconciliation_id :bigint           not null
#  resident_id       :bigint           not null
#
# Indexes
#
#  index_recon_balances_on_recon_id_and_resident_id  (reconciliation_id,resident_id) UNIQUE
#  index_reconciliation_balances_on_resident_id      (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (resident_id => residents.id)
#
require 'rails_helper'

RSpec.describe ReconciliationBalance do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }

  # Every example reads a row a real settlement stored. None adds a lone
  # row to a settled reconciliation: the database refuses that at commit,
  # because a reconciliation's balances must sum to zero
  # (spec/db/settled_balance_triggers_spec.rb), and a spec that did it
  # would pass only because its transaction is rolled back.
  #
  # By default one meal: the cook spent $50 and both ate, $12.50 a unit
  # of multiplier, so the eater owes $25 and the cook is owed $50 - $25.
  def settle_meals(bill: BigDecimal('50'), count: 1)
    count.times do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: bill)
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
    settle!(cutoff: Date.yesterday)
  end

  describe 'associations' do
    it 'belongs to a reconciliation and resident' do
      reconciliation = settle_meals
      balance = reconciliation.reconciliation_balances.find_by!(resident: eater)

      expect(balance.reconciliation).to eq(reconciliation)
      expect(balance.resident).to eq(eater)
    end
  end

  describe 'validations' do
    it 'enforces uniqueness of resident per reconciliation' do
      reconciliation = settle_meals

      duplicate = described_class.new(reconciliation: reconciliation, resident: eater, amount: BigDecimal('1'))

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:resident_id]).to eq(['has already been taken'])
    end
  end

  # A settled balance is what a resident has already been billed. These
  # guards are the readable half; the database triggers behind them are
  # covered in spec/db/settled_balance_triggers_spec.rb, which is where the
  # writes that skip callbacks are tested.
  describe 'immutability' do
    let(:balance) { settle_meals.reconciliation_balances.find_by!(resident: eater) }

    it 'starts from the amount the settlement stored' do
      expect(balance.amount).to eq(BigDecimal('-25'))
    end

    it 'refuses an update and keeps the stored amount' do
      expect(balance.update(amount: BigDecimal('1'))).to be(false)
      expect(balance.reload.amount).to eq(BigDecimal('-25'))
    end

    it 'refuses a destroy and keeps the row' do
      expect(balance.destroy).to be(false)
      expect(described_class.exists?(balance.id)).to be(true)
    end

    it 'explains that corrections belong in the next reconciliation' do
      balance.update(amount: BigDecimal('1'))

      expect(balance.errors[:base].join).to include('next reconciliation')
    end
  end

  # A balance is a sum, and nothing caps a sum: the column is
  # DECIMAL(16, 8), not the DECIMAL(12, 8) of a single bill, which holds
  # at most 9999.99999999 and overflowed in #60. Three $9,999.99 meals
  # shared by two adults leave the eater owing 3 * $4,999.995, which is
  # $14,999.98 once rounded toward zero to cents.
  describe 'amount precision' do
    it 'keeps a settled balance over $10,000 to the cent, as a BigDecimal' do
      reconciliation = settle_meals(bill: BigDecimal('9999.99'), count: 3)

      balance = reconciliation.reconciliation_balances.find_by!(resident: eater).reload

      expect(balance.amount).to eq(BigDecimal('-14999.98'))
      expect(balance.amount).to be_a(BigDecimal)
    end
  end
end

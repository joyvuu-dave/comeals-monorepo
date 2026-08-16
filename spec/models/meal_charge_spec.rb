# frozen_string_literal: true

require 'rails_helper'

# == Schema Information
#
# Table name: meal_charges
#
#  id          :bigint           not null, primary key
#  amount      :decimal(12, 8)   not null
#  bill_amount :decimal(12, 8)
#  kind        :string           not null
#  multiplier  :integer
#  unit_cost   :decimal(12, 8)   not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_meal_charges_on_meal_id              (meal_id)
#  index_meal_charges_on_resident_id          (resident_id)
#  index_meal_charges_one_credit_per_cook     (meal_id,resident_id) UNIQUE WHERE ((kind)::text = 'credit'::text)
#  index_meal_charges_one_debit_per_attendee  (meal_id,resident_id) UNIQUE WHERE ((kind)::text = 'debit'::text)
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#
RSpec.describe MealCharge do
  let(:community) { create(:community, cap: BigDecimal('4.50')) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

  # $16 across four units of multiplier: $4 a unit, so each of the two adults
  # is charged $8 and the cook is credited the whole $16. The cap allows
  # 4 * $4.50 = $18, so nothing here is subsidized — that case has its own
  # example below.
  def settle_plain_meal
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    Reconciliation.create!(community: community, end_date: Date.yesterday)
  end

  describe 'what settlement writes' do
    it 'writes one line per source row' do
      reconciliation = settle_plain_meal
      charges = described_class.for_reconciliation(reconciliation)

      expect(charges.count).to eq(3)
      expect(charges.where(kind: 'credit').count).to eq(1)
      expect(charges.where(kind: %w[debit guest_debit]).count).to eq(2)
    end

    it 'writes a credit that explains the cook' do
      settle_plain_meal
      credit = described_class.where(kind: 'credit').first

      expect(credit.resident_id).to eq(cook.id)
      expect(credit.amount).to eq(BigDecimal('16'))
      expect(credit.bill_amount).to eq(BigDecimal('16'))
      expect(credit.multiplier).to be_nil
      expect(credit).not_to be_subsidized
    end

    it 'writes a debit that explains one attendee' do
      settle_plain_meal
      debit = described_class.where(kind: %w[debit guest_debit]).find_by(resident: eater)

      expect(debit.amount).to eq(BigDecimal('-8'))
      expect(debit.multiplier).to eq(2)
      expect(debit.unit_cost).to eq(BigDecimal('4'))
      expect(debit.bill_amount).to be_nil
    end

    it 'records what a cook spent next to the smaller amount they were credited' do
      # 4 units of multiplier * 4.50 = 18.00 allowed, against 60.00 spent.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      credit = described_class.where(kind: 'credit').first

      expect(credit.amount).to eq(BigDecimal('18'))
      expect(credit.bill_amount).to eq(BigDecimal('60'))
      expect(credit).to be_subsidized
    end

    it 'charges each guest to the resident who brought them, one line each' do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      create(:guest, meal: meal, resident: eater, multiplier: 2)
      create(:guest, meal: meal, resident: eater, multiplier: 1)
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      guest_lines = described_class.where(kind: 'guest_debit')

      expect(guest_lines.count).to eq(2)
      expect(guest_lines.pluck(:resident_id).uniq).to eq([eater.id])
      expect(guest_lines.pluck(:multiplier)).to contain_exactly(1, 2)
    end

    it 'writes no line for a no_cost bill' do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
      create(:bill, meal: meal, resident: eater, community: community, amount: BigDecimal('9'), no_cost: true)
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      expect(described_class.where(kind: 'credit').pluck(:resident_id)).to eq([cook.id])
    end

    # The tie-out the nightly check relies on. Worth asserting here too,
    # because if it were ever false the check would only say so at 5am.
    it 'adds up, per resident, to the balance that was stored' do
      reconciliation = settle_plain_meal

      summed = described_class.for_reconciliation(reconciliation).group(:resident_id).sum(:amount)

      reconciliation.reconciliation_balances.each do |balance|
        expect(summed[balance.resident_id]).to eq(balance.amount)
      end
    end
  end

  describe 'immutability' do
    it 'refuses an update through Rails' do
      settle_plain_meal
      charge = described_class.first

      expect(charge.update(amount: BigDecimal('1'))).to be(false)
      expect(charge.reload.amount).not_to eq(BigDecimal('1'))
    end

    it 'refuses a destroy through Rails' do
      settle_plain_meal
      charge = described_class.first

      expect(charge.destroy).to be(false)
      expect(described_class.exists?(charge.id)).to be(true)
    end

    it 'refuses an update that skips Rails' do
      settle_plain_meal
      charge = described_class.first

      expect { described_class.where(id: charge.id).update_all(amount: BigDecimal('1')) }
        .to raise_error(ActiveRecord::StatementInvalid, /meal_charges refused/)
    end

    it 'refuses a delete that skips Rails' do
      settle_plain_meal
      charge = described_class.first

      expect { described_class.where(id: charge.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /meal_charges refused/)
    end
  end

  describe 'database constraints' do
    let(:meal) { create(:meal, community: community) }

    def insert(**attributes)
      described_class.insert_all!([{
        meal_id: meal.id, resident_id: cook.id, unit_cost: BigDecimal('1'),
        created_at: Time.current, updated_at: Time.current
      }.merge(attributes)])
    end

    it 'refuses an unknown kind' do
      expect { insert(kind: 'refund', amount: BigDecimal('1')) }
        .to raise_error(ActiveRecord::StatementInvalid, /kind_known/)
    end

    it 'refuses a credit with no bill amount' do
      expect { insert(kind: 'credit', amount: BigDecimal('1')) }
        .to raise_error(ActiveRecord::StatementInvalid, /bill_amount_on_credits_only/)
    end

    it 'refuses a debit that carries a bill amount' do
      expect { insert(kind: 'debit', amount: BigDecimal('-1'), multiplier: 2, bill_amount: BigDecimal('1')) }
        .to raise_error(ActiveRecord::StatementInvalid, /bill_amount_on_credits_only/)
    end

    it 'refuses a credit that carries a multiplier' do
      expect { insert(kind: 'credit', amount: BigDecimal('1'), bill_amount: BigDecimal('1'), multiplier: 2) }
        .to raise_error(ActiveRecord::StatementInvalid, /multiplier_on_debits_only/)
    end

    it 'refuses a debit with no multiplier' do
      expect { insert(kind: 'debit', amount: BigDecimal('-1')) }
        .to raise_error(ActiveRecord::StatementInvalid, /multiplier_on_debits_only/)
    end

    # Mirrors the uniqueness of the source rows. Guests are deliberately not
    # unique — one resident may bring several — and that is covered above.
    it 'refuses a second credit for the same cook on the same meal' do
      insert(kind: 'credit', amount: BigDecimal('1'), bill_amount: BigDecimal('1'))

      expect { insert(kind: 'credit', amount: BigDecimal('2'), bill_amount: BigDecimal('2')) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'refuses a second debit for the same attendee on the same meal' do
      insert(kind: 'debit', amount: BigDecimal('-1'), multiplier: 2)

      expect { insert(kind: 'debit', amount: BigDecimal('-2'), multiplier: 2) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end

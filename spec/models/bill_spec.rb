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

    it 'reports a missing amount instead of failing to round it' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      bill = build(:bill, meal: meal, resident: resident, community: community, amount: nil)

      expect(bill).not_to be_valid
      expect(bill.errors[:amount]).to eq(['is not a number'])
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

  # A cost the cook has not entered yet (Meal.a_cost_not_entered, for a
  # bill in hand).
  describe '#cost_not_entered?' do
    it 'is true for $0 not marked No cost, and false for a cost or No cost' do
      expect([build(:bill, amount: BigDecimal('0'), no_cost: false),
              build(:bill, amount: BigDecimal('0.01'), no_cost: false),
              build(:bill, amount: BigDecimal('0'), no_cost: true)].map(&:cost_not_entered?))
        .to eq([true, false, false])
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

  # A bill is "this cook on this meal" (ADR 0009, #135). An admin who
  # changed a bill's cook in place made the meal history wrong: it said
  # "unknown bill changed", and the cook's older lines then named the new
  # cook. To fix a wrong cook or meal, delete the bill and add a new one.
  describe 'a saved bill keeps its cook and its meal' do
    let(:meal) { create(:meal, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit) }
    let(:other_cook) { create(:resident, community: community, unit: unit) }
    let(:bill) { create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50')) }

    it 'refuses a new cook in words, and keeps the cook it had' do
      bill.resident = other_cook

      expect(bill.save).to be(false)
      expect(bill.errors.full_messages).to eq([Bill::COOK_AND_MEAL_FIXED])
      expect(bill.reload.resident_id).to eq(cook.id)
    end

    it 'refuses a new meal in words, and keeps the meal it had, when both meals are open' do
      other_meal = create(:meal, community: community, date: meal.date + 1)
      bill.meal = other_meal

      expect(bill.save).to be(false)
      expect(bill.errors.full_messages).to eq([Bill::COOK_AND_MEAL_FIXED])
      expect(bill.reload.meal_id).to eq(meal.id)
    end

    it 'refuses a new cook from a save that skips validation' do
      bill.resident_id = other_cook.id

      expect(bill.save(validate: false)).to be(false)
      expect(bill.errors.full_messages).to eq([Bill::COOK_AND_MEAL_FIXED])
      expect(bill.reload.resident_id).to eq(cook.id)
    end

    # The before_save gives the same sentence, but it never runs when
    # another mistake fails validation first. Without the validation, this
    # save would show only the cents error and hide the cook refusal.
    it 'says the cook and meal cannot change along with any other mistake in the same save' do
      bill.assign_attributes(resident: other_cook, amount: BigDecimal('40.555'))

      expect(bill.save).to be(false)
      expect(bill.errors.full_messages).to contain_exactly(Bill::COOK_AND_MEAL_FIXED, 'Amount must be whole cents')
    end

    it 'saves when the cook and meal are given again unchanged, as a string the way a form sends them' do
      bill.assign_attributes(resident_id: cook.id.to_s, meal_id: meal.id.to_s, amount: BigDecimal('60'))

      expect(bill.save).to be(true)
      expect(bill.reload.amount).to eq(BigDecimal('60'))
    end

    it 'takes any cook and any meal on a new bill' do
      new_bill = build(:bill, meal: meal, resident: other_cook, community: community)

      expect(new_bill.save).to be(true)
    end
  end

  # "No cost" means the cook spent nothing, so a bill marked No cost has
  # no amount. Before 2026-10-10 nothing refused both at once. MealLedger
  # leaves a no-cost bill out of the meal's cost, so a cook whose bill had
  # both was credited $0 for what they spent: 27 bills in the production
  # copy of September 2026. The database CHECK bills_no_cost_means_no_amount
  # refuses the same rows from writes that skip the model
  # (spec/db/bills_no_cost_means_no_amount_check_spec.rb).
  describe 'a bill marked No cost has no amount' do
    let(:meal) { create(:meal, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit) }

    it 'refuses No cost on a bill with an amount, in words, and keeps the stored bill' do
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('86'))
      bill.no_cost = true

      expect(bill.save).to be(false)
      expect(bill.errors.full_messages)
        .to eq(["A bill marked No cost can't have an amount. Clear the amount, or turn No cost off."])
      expect(bill.reload.no_cost).to be(false)
    end

    it 'refuses an amount on a bill marked No cost' do
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: 0, no_cost: true)

      expect(bill.update(amount: BigDecimal('0.01'))).to be(false)
      expect(bill.errors.full_messages).to eq([described_class::NO_COST_MEANS_NO_AMOUNT])
      expect(bill.reload.amount).to eq(0)
    end

    it 'refuses a new bill with both' do
      bill = build(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('12'), no_cost: true)

      expect(bill).not_to be_valid
      expect(bill.errors.full_messages).to eq([described_class::NO_COST_MEANS_NO_AMOUNT])
    end

    # A blank amount (Rails reads "" as nil) or a negative one already
    # has its own error. No cost adds nothing to it, and must not fail
    # trying to compare a nil.
    it 'leaves a missing or negative amount on a No cost bill to the amount\'s own error' do
      missing = build(:bill, meal: meal, resident: cook, community: community, amount: nil, no_cost: true)
      negative = build(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('-1'),
                              no_cost: true)

      expect(missing).not_to be_valid
      expect(missing.errors.full_messages).to eq(['Amount is not a number'])
      expect(negative).not_to be_valid
      expect(negative.errors.full_messages).to eq(['Amount must be greater than or equal to 0'])
    end

    it 'takes No cost with $0, and an amount without No cost' do
      expect(build(:bill, meal: meal, resident: cook, community: community, amount: 0, no_cost: true)).to be_valid
      expect(build(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('12'))).to be_valid
    end
  end

  # Issue #139. Every true/false column is NOT NULL. Without this check a
  # nil (a no_cost sent as "" in the bills format before #135, which Rails
  # reads as nil) reached the database, and the API answered 500. The
  # model refuses it with a sentence, so every path gets a readable error.
  describe 'the no_cost column' do
    it 'refuses a nil with a sentence, and keeps the stored value' do
      record = create(:bill, community: community, meal: create(:meal, community: community),
                             resident: create(:resident, community: community, unit: unit))
      stored = record.no_cost
      record.no_cost = nil

      expect(record.save).to be(false)
      expect(record.errors.full_messages).to eq(['No cost must be true or false'])
      expect(record.reload.no_cost).to eq(stored)
    end
  end
end

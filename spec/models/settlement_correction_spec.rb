# frozen_string_literal: true

# == Schema Information
#
# Table name: settlement_corrections
#
#  id                          :bigint           not null, primary key
#  earlier_differences         :jsonb            not null
#  include_earlier_differences :boolean          default(FALSE), not null
#  reason                      :text             not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  reconciliation_id           :bigint           not null
#
# Indexes
#
#  index_settlement_corrections_on_reconciliation_id  (reconciliation_id)
#
# Foreign Keys
#
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#
require 'rails_helper'

# The record a settlement correction leaves (Settlement#correct!): the
# correction, a line per changed balance, and a copy of each line item it
# replaced. It is evidence of what a settlement said before and after, so
# nothing changes or deletes it: the model refuses in words, and the
# database refuses writes that skip the model. Only Settlement#correct!
# adds to it, while it works that settlement out again
# (comeals_settlement_correction_insert_by_settlement in db/structure.sql).
RSpec.describe SettlementCorrection do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Casey Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Dana Diner') }
  let(:reconciliation) do
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!(cutoff: Date.new(2025, 3, 31))
  end
  let(:charge) { MealCharge.for_reconciliation(reconciliation).find_by!(resident: cook) }
  # Written the way Settlement#correct! writes them: as that settlement.
  let(:correction) do
    SettledWrites.as_settlement_of(reconciliation) do
      described_class.create!(reconciliation: reconciliation, reason: 'A cost was wrong.')
    end
  end
  # The correction first: its own let turns the setting off when it ends.
  let(:line) do
    owner = correction
    SettledWrites.as_settlement_of(reconciliation) do
      SettlementCorrectionLine.create!(settlement_correction: owner, resident: cook,
                                       old_amount: BigDecimal('20'), new_amount: BigDecimal('30'))
    end
  end
  let(:kept) do
    owner = correction
    old = charge
    SettledWrites.as_settlement_of(reconciliation) do
      SettlementCorrectionCharge.create!(
        settlement_correction: owner, meal_charge_id: old.id, meal: old.meal, resident: cook,
        kind: old.kind, amount: old.amount, unit_cost: old.unit_cost, bill_amount: old.bill_amount,
        charged_at: old.created_at
      )
    end
  end

  describe 'the model' do
    it 'refuses to change a correction, in words' do
      expect(correction.update(reason: 'Something else.')).to be(false)
      expect(correction.errors[:base].first).to start_with('A settlement correction is a record')
    end

    it 'refuses to delete a correction, in words' do
      expect(correction.destroy).to be(false)
      expect(correction.errors[:base].first).to start_with('A settlement correction is a record')
    end

    it 'refuses to change or delete a line, in words' do
      expect(line.update(new_amount: BigDecimal('31'))).to be(false)
      expect(line.destroy).to be(false)
      expect(line.errors[:base].first).to start_with('A settlement correction is a record')
    end

    it 'refuses to change or delete a kept line item, in words' do
      expect(kept.update(amount: BigDecimal('1'))).to be(false)
      expect(kept.destroy).to be(false)
      expect(kept.errors[:base].first).to start_with('A settlement correction is a record')
    end

    it 'needs a reason' do
      expect(described_class.new(reconciliation: reconciliation, reason: ' ')).not_to be_valid
    end

    # A clean correction found nothing before it. Only a caller that let
    # the correction fold earlier differences in has any to keep.
    it 'keeps earlier differences only when the caller let the correction fold them in' do
      found = [{ 'reconciliation_id' => 1, 'check' => 'recompute', 'differences' => [] }]

      expect(described_class.new(reconciliation: reconciliation, reason: 'x', earlier_differences: found))
        .not_to be_valid
      expect(described_class.new(reconciliation: reconciliation, reason: 'x', earlier_differences: found,
                                 include_earlier_differences: true)).to be_valid
    end

    # A person whose balance did not change has no line.
    it 'refuses a line whose amount did not change, in words' do
      same = SettlementCorrectionLine.new(settlement_correction: correction, resident: cook,
                                          old_amount: BigDecimal('30'), new_amount: BigDecimal('30'))

      expect(same).not_to be_valid
      expect(same.errors[:new_amount]).to eq(['must be other than 30.0'])
    end

    it "lists a settlement's corrections oldest first" do
      first = correction
      later = SettledWrites.as_settlement_of(reconciliation) do
        described_class.create!(reconciliation: reconciliation, reason: 'Another cost was wrong.')
      end

      expect(reconciliation.settlement_corrections.reload).to eq([first, later])
    end
  end

  describe 'the database' do
    it 'refuses an update or a delete that skips the model' do
      expect { described_class.where(id: correction.id).update_all(reason: 'x') }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE on settlement_corrections refused/)
    end

    it 'refuses to delete a line that skips the model' do
      line
      expect { SettlementCorrectionLine.where(id: line.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /DELETE on settlement_correction_lines refused/)
    end

    it 'refuses to change a kept line item that skips the model' do
      kept
      expect { SettlementCorrectionCharge.where(id: kept.id).update_all(amount: 1) }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE on settlement_correction_charges refused/)
    end

    it 'lets the repair bypass through' do
      line
      SettledWrites.with_repair_bypass { SettlementCorrectionLine.where(id: line.id).delete_all }

      expect(SettlementCorrectionLine.exists?(line.id)).to be(false)
    end

    # Only Settlement#correct! writes a correction, as that settlement. A
    # row added any other way would be a record of a correction that never
    # happened.
    it 'refuses a correction added outside its settlement' do
      expect { described_class.create!(reconciliation: reconciliation, reason: 'Made up.') }
        .to raise_error(ActiveRecord::StatementInvalid, /INSERT on settlement_corrections refused/)
    end

    it "refuses a correction written as another settlement's" do
      another = (reconciliation.id + 1).to_s

      expect do
        SettledWrites.with_local_setting(Settlement::SETTLING_SETTING, another) do
          described_class.create!(reconciliation: reconciliation, reason: 'Made up.')
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /INSERT on settlement_corrections refused/)
    end

    it 'refuses a line added outside its settlement' do
      correction
      expect do
        SettlementCorrectionLine.insert_all!([{ settlement_correction_id: correction.id, resident_id: cook.id,
                                                old_amount: BigDecimal('1'), new_amount: BigDecimal('2') }])
      end.to raise_error(ActiveRecord::StatementInvalid, /INSERT on settlement_correction_lines refused/)
    end

    it 'refuses a kept line item added outside its settlement' do
      correction
      expect do
        SettlementCorrectionCharge.insert_all!([{ settlement_correction_id: correction.id, meal_charge_id: 1,
                                                  meal_id: charge.meal_id, resident_id: cook.id, kind: 'credit',
                                                  amount: 1, unit_cost: 1, charged_at: Time.current }])
      end.to raise_error(ActiveRecord::StatementInvalid, /INSERT on settlement_correction_charges refused/)
    end

    it 'lets the repair bypass add a correction' do
      SettledWrites.with_repair_bypass do
        described_class.create!(reconciliation: reconciliation, reason: 'A repair by hand.')
      end

      expect(described_class.count).to eq(1)
    end

    # Each refused insert runs inside the settlement's own savepoint, so
    # the refusal rolls that back and the example's transaction goes on.
    it 'refuses earlier differences on a correction that was not allowed to fold them in' do
      expect do
        SettledWrites.as_settlement_of(reconciliation) do
          described_class.insert_all!([{ reconciliation_id: reconciliation.id, reason: 'x',
                                         earlier_differences: [{ check: 'recompute' }] }])
        end
      end.to raise_error(ActiveRecord::StatementInvalid,
                         /settlement_corrections_earlier_differences_only_when_included/)
    end

    it 'refuses earlier differences that are not a list' do
      expect do
        SettledWrites.as_settlement_of(reconciliation) do
          described_class.insert_all!([{ reconciliation_id: reconciliation.id, reason: 'x',
                                         include_earlier_differences: true, earlier_differences: { check: 'x' } }])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /settlement_corrections_earlier_differences_list/)
    end

    it 'refuses a blank reason' do
      expect do
        SettledWrites.as_settlement_of(reconciliation) do
          described_class.insert_all!([{ reconciliation_id: reconciliation.id, reason: '  ' }])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /settlement_corrections_reason_present/)
    end

    it 'refuses a line whose amount did not change' do
      correction
      expect do
        SettledWrites.as_settlement_of(reconciliation) do
          SettlementCorrectionLine.insert_all!([{ settlement_correction_id: correction.id, resident_id: cook.id,
                                                  old_amount: BigDecimal('30'), new_amount: BigDecimal('30') }])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /settlement_correction_lines_changed/)
    end

    it 'refuses two lines for one person in one correction' do
      line
      expect do
        SettledWrites.as_settlement_of(reconciliation) do
          SettlementCorrectionLine.insert_all!([{ settlement_correction_id: correction.id, resident_id: cook.id,
                                                  old_amount: BigDecimal('1'), new_amount: BigDecimal('2') }])
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end

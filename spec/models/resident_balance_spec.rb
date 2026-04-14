# frozen_string_literal: true

# == Schema Information
#
# Table name: resident_balances
#
#  id          :bigint           not null, primary key
#  amount      :decimal(12, 8)   default(0.0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_resident_balances_on_resident_id  (resident_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (resident_id => residents.id)
#
require 'rails_helper'

RSpec.describe ResidentBalance do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  describe 'validations' do
    # Regression test for BUG-2: resident_balances must enforce one record per
    # resident at both the model and database level to prevent stale duplicates.
    it 'enforces uniqueness of resident_id at the model level' do
      described_class.create!(resident: resident, amount: BigDecimal('10'))

      duplicate = described_class.new(resident: resident, amount: BigDecimal('20'))
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:resident_id]).to be_present
    end

    it 'enforces uniqueness of resident_id at the database level' do
      described_class.create!(resident: resident, amount: BigDecimal('10'))

      duplicate = described_class.new(resident: resident, amount: BigDecimal('20'))
      expect do
        duplicate.save(validate: false)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end

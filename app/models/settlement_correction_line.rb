# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: settlement_correction_lines
#
#  id                       :bigint           not null, primary key
#  new_amount               :decimal(16, 8)   not null
#  old_amount               :decimal(16, 8)   not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  resident_id              :bigint           not null
#  settlement_correction_id :bigint           not null
#
# Indexes
#
#  index_correction_lines_on_correction_and_resident  (settlement_correction_id,resident_id) UNIQUE
#  index_settlement_correction_lines_on_resident_id   (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (resident_id => residents.id)
#  fk_rails_...  (settlement_correction_id => settlement_corrections.id)
#
# One person's settled balance before and after a SettlementCorrection.
#
# Both amounts are signed the way a settled balance is (ReconciliationBalance):
# positive means the community owes the person. Zero means the person had
# no balance on that side. Never show the sign to a person: screens render
# both through BalanceDisplayHelper#balance_tag.
class SettlementCorrectionLine < ApplicationRecord
  belongs_to :settlement_correction, inverse_of: :lines
  belongs_to :resident

  validates :old_amount, :new_amount, numericality: true
  validates :resident_id, uniqueness: { scope: :settlement_correction_id }
  # A person whose balance did not change has no line. The CHECK
  # settlement_correction_lines_changed refuses one too.
  validates :new_amount, comparison: { other_than: :old_amount }

  # Append-only, like the correction it belongs to.
  include AppendOnly

  append_only update_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                              'and cannot be modified.',
              destroy_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                               'and cannot be destroyed.'
end

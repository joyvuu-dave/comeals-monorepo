# typed: strict
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
# A settlement whose numbers were worked out again after it was made, and
# why. Written only by Settlement#correct!, in the same transaction that
# replaced the settlement's balances and line items. Its lines name each
# person whose balance changed, with the amount before and after; its
# charges are the line items it deleted, as they were (a settlement made
# before 2026-08-02 has none). The database refuses an UPDATE or DELETE
# on the three tables (comeals_protect_settlement_correction), and an
# INSERT unless Settlement#correct! is writing it under comeals.settling
# (comeals_settlement_correction_insert_by_settlement).
class SettlementCorrection < ApplicationRecord
  belongs_to :reconciliation
  has_many :lines, class_name: 'SettlementCorrectionLine', dependent: :restrict_with_exception,
                   inverse_of: :settlement_correction
  has_many :charges, class_name: 'SettlementCorrectionCharge', dependent: :restrict_with_exception,
                     inverse_of: :settlement_correction

  validates :reason, presence: true
  validates :include_earlier_differences, inclusion: { in: [true, false], message: TrueOrFalse::MESSAGE }
  # The CHECK settlement_corrections_earlier_differences_only_when_included
  # refuses the same: a clean correction found nothing before it.
  validates :earlier_differences, absence: true, unless: :include_earlier_differences

  # Append-only. The database trigger comeals_protect_settlement_correction
  # refuses the writes that skip callbacks.
  include AppendOnly

  append_only update_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                              'and cannot be modified.',
              destroy_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                               'and cannot be destroyed.'
end

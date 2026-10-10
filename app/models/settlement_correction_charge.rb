# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: settlement_correction_charges
#
#  id                       :bigint           not null, primary key
#  amount                   :decimal(16, 8)   not null
#  bill_amount              :decimal(12, 8)
#  charged_at               :datetime         not null
#  kind                     :string           not null
#  multiplier               :integer
#  unit_cost                :decimal(16, 8)   not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  meal_charge_id           :bigint           not null
#  meal_id                  :bigint           not null
#  resident_id              :bigint           not null
#  settlement_correction_id :bigint           not null
#
# Indexes
#
#  idx_on_settlement_correction_id_2e132aa3fc          (settlement_correction_id)
#  index_settlement_correction_charges_on_meal_id      (meal_id)
#  index_settlement_correction_charges_on_resident_id  (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#  fk_rails_...  (settlement_correction_id => settlement_corrections.id)
#
# A settlement line item (MealCharge) as it was before a SettlementCorrection
# deleted it, column for column: its old id (meal_charge_id), and the time
# the settlement wrote it (charged_at). Written only by Settlement#correct!,
# in the same transaction that deleted the line item. Signed like a
# MealCharge: a credit is positive.
class SettlementCorrectionCharge < ApplicationRecord
  belongs_to :settlement_correction, inverse_of: :charges
  belongs_to :meal
  belongs_to :resident

  validates :meal_charge_id, :kind, :charged_at, presence: true
  validates :amount, :unit_cost, numericality: true

  # Append-only, like the correction it belongs to.
  include AppendOnly

  append_only update_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                              'and cannot be modified.',
              destroy_message: 'A settlement correction is a record of what a settlement said before and after, ' \
                               'and cannot be destroyed.'
end

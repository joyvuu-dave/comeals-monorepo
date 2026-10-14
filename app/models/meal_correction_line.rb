# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_correction_lines
#
#  id                 :bigint           not null, primary key
#  amount             :decimal(16, 8)   not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  meal_correction_id :bigint           not null
#  resident_id        :bigint           not null
#
# Indexes
#
#  index_meal_correction_lines_on_resident_id  (resident_id)
#  index_meal_correction_lines_once_a_person   (meal_correction_id,resident_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (meal_correction_id => meal_corrections.id)
#  fk_rails_...  (resident_id => residents.id)
#
# One person's change from a MealCorrection, at the ledger grain.
#
# Signed the way a settled balance is (MealLedger, "Signs"): positive
# means the community owes the person more. A correction's lines add up
# to exactly zero (the trigger comeals_meal_correction_lines_sum_zero).
# Never show the sign to a person: screens render it through
# BalanceDisplayHelper.
class MealCorrectionLine < ApplicationRecord
  belongs_to :meal_correction, inverse_of: :lines
  belongs_to :resident

  validates :amount, numericality: { other_than: 0 }
  validates :resident_id, uniqueness: { scope: :meal_correction_id }

  include AppendOnly

  append_only update_message: 'A correction is a record of what changed on a settled dinner, and cannot be modified.',
              destroy_message: 'A correction is a record of what changed on a settled dinner, and cannot be ' \
                               'destroyed.'
end

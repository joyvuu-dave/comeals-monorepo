# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_corrections
#
#  id                :bigint           not null, primary key
#  edits             :jsonb            not null
#  reason            :text             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  admin_user_id     :bigint           not null
#  meal_id           :bigint           not null
#  reconciliation_id :bigint
#
# Indexes
#
#  index_meal_corrections_on_admin_user_id      (admin_user_id)
#  index_meal_corrections_on_meal_id            (meal_id)
#  index_meal_corrections_on_reconciliation_id  (reconciliation_id)
#
# Foreign Keys
#
#  fk_rails_...  (admin_user_id => admin_users.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#
# A correction to a settled dinner (ADR 0011 rule 6): who made it and why,
# what it changed, and each person's change in what they owe or are owed.
# Written only by MealCorrecting, in the same transaction that changed the
# dinner's rows. The old settlement keeps what it settled; the next
# settlement carries this correction (reconciliation, empty until then)
# and adds its lines to the balances it rounds to cents. The table
# comment is in migration 20261013130000.
class MealCorrection < ApplicationRecord
  extend T::Sig

  belongs_to :meal
  belongs_to :admin_user
  # The settlement that carries this correction. Empty until one does.
  belongs_to :reconciliation, optional: true
  has_many :lines, class_name: 'MealCorrectionLine', dependent: :restrict_with_exception,
                   inverse_of: :meal_correction

  # Not carried by any settlement yet. The next settlement claims these,
  # and the running balances add them in until it does.
  scope :waiting, -> { where(reconciliation_id: nil) }

  validates :reason, presence: true

  # Append-only. A settlement claims a correction with update_all, which
  # skips this; the database trigger in 20261013130000 allows that one
  # change and refuses every other.
  include AppendOnly

  append_only update_message: 'A correction is a record of what changed on a settled dinner, and cannot be modified.',
              destroy_message: 'A correction is a record of what changed on a settled dinner, and cannot be ' \
                               'destroyed.'
end

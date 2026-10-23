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
# and adds its lines to the balances it rounds to cents. The database
# keeps the rules for writes that skip the model, in
# comeals_meal_correction_guard, comeals_meal_correction_line_guard and
# comeals_meal_correction_lines_sum_zero: a correction and its lines are
# added only to a settled dinner while it is being corrected
# (comeals.correcting names it), the lines add up to zero, and nothing
# changes afterwards except the claim by a later settlement.
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

  # Each correction once for each edit in its record that added, removed
  # or changed a cook's cost, with that edit as cost_edit.edit and its
  # place in the record (from 1) as cost_edit.place. COOK_ID and
  # COST_BEFORE read the edit.
  scope :cost_edits, lambda {
    joins('CROSS JOIN LATERAL jsonb_array_elements(meal_corrections.edits) WITH ORDINALITY AS cost_edit(edit, place)')
      .where("cost_edit.edit ->> 'what' = 'cost'")
  }
  # The cook a cost edit names.
  COOK_ID = T.let(Arel.sql("(cost_edit.edit ->> 'resident_id')::bigint"), Arel::Nodes::SqlLiteral)
  # The cook's cost before the edit, as JSON: an object, or null when they
  # were not a cook.
  COST_BEFORE = T.let(Arel.sql("cost_edit.edit -> 'from'"), Arel::Nodes::SqlLiteral)

  validates :reason, presence: true

  # Append-only. A settlement claims a correction with update_all, which
  # skips this; the database trigger comeals_meal_correction_guard allows that one
  # change and refuses every other.
  include AppendOnly

  append_only update_message: 'A correction is a record of what changed on a settled dinner, and cannot be modified.',
              destroy_message: 'A correction is a record of what changed on a settled dinner, and cannot be ' \
                               'destroyed.'

  # The edits in this correction's record that added, removed or changed
  # this resident's cost.
  sig { params(resident: Resident).returns(T::Array[T::Hash[String, T.untyped]]) }
  def cost_edits_of(resident)
    T.let(edits, T::Array[T::Hash[String, T.untyped]])
     .select { |edit| edit['what'] == 'cost' && edit['resident_id'] == resident.id }
  end
end

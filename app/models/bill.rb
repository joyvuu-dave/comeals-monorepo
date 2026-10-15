# typed: strict
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
class Bill < ApplicationRecord
  extend T::Sig

  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin filtering and sorting
  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_attributes(_auth_object = nil)
    %w[id amount no_cost meal_id resident_id created_at updated_at]
  end

  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_associations(_auth_object = nil)
    %w[meal resident]
  end

  belongs_to :meal, inverse_of: :bills, touch: true
  belongs_to :resident

  audited associated_with: :meal

  # Prepended before_save and before_destroy: the meal lock is taken
  # before the row is written, in the trigger's order. The reconciled
  # guard's validation runs earlier, before any before_save, so it does
  # not read under this lock (its before_save reads the row again, and
  # does); the SERIALIZABLE transaction they share with the write keeps
  # their answer and the write together. See the concern.
  include LocksItsMealFirst

  # ActiveAdmin's Bill form would otherwise allow a superuser to quietly
  # rewrite a reconciled bill's amount.
  include ReconciledMealImmutability
  # Nor changed on a cancelled dinner, until it is restored.
  include CancelledDinnerFreeze
  include NotesMealLiveUpdate

  # A bill is "this cook on this meal" (ADR 0009, #135), so a saved bill
  # never gets a new cook or a new meal. To fix a wrong one, an admin
  # deletes the bill and adds a new one, and the meal history then says
  # who was removed and who was added. Before 2026-10-10 the admin form
  # could change the cook in place. The history then said "unknown bill
  # changed", and the cook's older lines named the new cook.
  #
  # Two hooks, one rule, as in ReconciledMealImmutability: the
  # validation gives the sentence along with any other mistakes on the
  # form, and the before_save covers a save that skips validation. A
  # write that skips the model (update_columns, update_all, psql) is
  # refused by the trigger bills_same_cook_and_meal, in these same words.
  COOK_AND_MEAL_FIXED = "A bill's cook and meal cannot change. " \
                        'To fix a wrong cook or meal, delete this bill and add a new one.'

  validate :refuse_new_cook_or_meal
  before_save :reject_new_cook_or_meal

  # "No cost" means the cook spent nothing, so a bill marked No cost has
  # no amount. MealLedger leaves a no-cost bill out of the meal's cost, so
  # a bill with both credited the cook $0 for what they spent. Before
  # April 2026 the meal page let a cost be typed into a row marked No
  # cost, and nothing refused it here until 2026-10-10. Migration
  # 20261010130000 turned No cost off on every bill that had both, and
  # worked out again each settlement that had left one out. The
  # bills_no_cost_means_no_amount CHECK refuses the same rows from writes
  # that skip the model (MODELS.md, Bill).
  NO_COST_MEANS_NO_AMOUNT = "A bill marked No cost can't have an amount. Clear the amount, or turn No cost off."

  validate :refuse_no_cost_with_an_amount

  delegate :date, to: :meal
  delegate :unit, to: :resident
  delegate :attendees_count, to: :meal

  # A cook's cost is whole cents, 0 to 9999.99 (the largest whole-cent value
  # DECIMAL(12,8) can hold). The API controller rejects amounts that break
  # this before they reach the model; this validation covers every other
  # write path (ActiveAdmin, console), and the bills_amount_whole_cents
  # CHECK constraint is the last line of defense.
  validates :amount, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal('9999.99') }
  validate :amount_in_whole_cents
  validates :resident_id, uniqueness: { scope: :meal_id }
  # NOT NULL. Without this a nil (a no_cost sent as "" in the bills
  # format before #135, which Rails reads as nil) reached the database,
  # and the API answered 500 (#139). Now it is refused with a sentence.
  validates :no_cost, inclusion: { in: [true, false], message: TrueOrFalse::MESSAGE }

  sig { void }
  def amount_in_whole_cents
    amount = self.amount
    return if amount.nil? || amount == amount.round(2)

    errors.add(:amount, 'must be whole cents')
  end

  delegate :reconciled?, to: :meal

  # The cook has not entered a cost yet: $0 and not marked No cost. The
  # same rule as Meal.a_cost_not_entered, for a bill already in hand.
  sig { returns(T::Boolean) }
  def cost_not_entered?
    !no_cost && T.must(amount).zero?
  end

  private

  sig { void }
  def refuse_new_cook_or_meal
    errors.add(:base, COOK_AND_MEAL_FIXED) if new_cook_or_meal?
  end

  # Only a positive amount: a nil or negative one has its own error from
  # the numericality validation.
  sig { void }
  def refuse_no_cost_with_an_amount
    amount = self.amount
    errors.add(:base, NO_COST_MEANS_NO_AMOUNT) if no_cost == true && !amount.nil? && amount.positive?
  end

  sig { void }
  def reject_new_cook_or_meal
    return unless new_cook_or_meal?

    errors.add(:base, COOK_AND_MEAL_FIXED)
    throw(:abort)
  end

  # A new bill takes any cook and any meal. A form that sends the same
  # cook or meal again, as a string, changes nothing: Rails compares the
  # value after turning it into a number.
  sig { returns(T::Boolean) }
  def new_cook_or_meal?
    persisted? && (will_save_change_to_resident_id? || will_save_change_to_meal_id?)
  end
end

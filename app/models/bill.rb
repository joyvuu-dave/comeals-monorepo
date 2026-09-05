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

  # ActiveAdmin's Bill form would otherwise allow a superuser to quietly
  # rewrite a reconciled bill's amount, or move it between meals.
  include ReconciledMealImmutability
  include NotesMealLiveUpdate

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

  sig { void }
  def amount_in_whole_cents
    amount = self.amount
    return if amount.nil? || amount == amount.round(2)

    errors.add(:amount, 'must be whole cents')
  end

  delegate :reconciled?, to: :meal
end

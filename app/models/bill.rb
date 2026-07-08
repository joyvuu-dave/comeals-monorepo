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
#  index_bills_on_meal_id                  (meal_id)
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
  # Ransack allowlists for ActiveAdmin filtering and sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id amount no_cost meal_id resident_id community_id created_at updated_at]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[meal resident]
  end

  belongs_to :meal, inverse_of: :bills, touch: true
  belongs_to :resident
  belongs_to :community

  audited associated_with: :meal

  # ActiveAdmin's Bill form would otherwise allow a superuser to quietly
  # rewrite a reconciled bill's amount, or move it between meals.
  include ReconciledMealImmutability

  delegate :date, to: :meal
  delegate :unit, to: :resident
  delegate :attendees_count, to: :meal

  before_validation :set_community_id

  # A cook's cost is whole cents, 0 to 9999.99 (the largest whole-cent value
  # DECIMAL(12,8) can hold). The API controller rejects amounts that break
  # this before they reach the model; this validation covers every other
  # write path (ActiveAdmin, console), and the bills_amount_whole_cents
  # CHECK constraint is the last line of defense.
  validates :amount, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal('9999.99') }
  validate :amount_in_whole_cents
  validates :resident_id, uniqueness: { scope: :meal_id }

  def set_community_id
    self.community_id = meal&.community_id
  end

  def amount_in_whole_cents
    return if amount.nil? || amount == amount.round(2)

    errors.add(:amount, 'must be whole cents')
  end

  # The amount used for cost-splitting purposes.
  # If no_cost is true, this cook's bill does not contribute to the meal cost.
  def effective_amount
    no_cost? ? BigDecimal('0') : amount
  end

  # Per-multiplier-unit cost for this bill.
  # Uses effective_amount so no_cost bills contribute 0.
  def unit_cost
    return BigDecimal('0') if meal.multiplier.zero?

    capped_amount / meal.multiplier
  end

  # The bill amount after applying the community cost cap.
  # If the meal is uncapped, returns the full effective_amount.
  # If capped, returns this bill's proportional share of the max cost.
  def capped_amount
    amt = effective_amount
    return amt unless persisted?
    return amt unless meal.capped?

    total = meal.total_cost
    return amt if total.zero?

    max = meal.max_cost
    return amt if total <= max

    (amt / total) * max
  end

  delegate :reconciled?, to: :meal
end

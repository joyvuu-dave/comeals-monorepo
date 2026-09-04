# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_charges
#
#  id          :bigint           not null, primary key
#  amount      :decimal(16, 8)   not null
#  bill_amount :decimal(12, 8)
#  kind        :string           not null
#  multiplier  :integer
#  unit_cost   :decimal(16, 8)   not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_meal_charges_on_meal_id              (meal_id)
#  index_meal_charges_on_resident_id          (resident_id)
#  index_meal_charges_one_credit_per_cook     (meal_id,resident_id) UNIQUE WHERE ((kind)::text = 'credit'::text)
#  index_meal_charges_one_debit_per_attendee  (meal_id,resident_id) UNIQUE WHERE ((kind)::text = 'debit'::text)
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#
# One line of a settlement: what one resident was charged or credited for one
# meal, and why. Written once inside the settlement transaction, from
# MealLedger. See the migration (20260802120000) for the reasoning.
#
# `amount` is signed the way MealLedger signs everything (see its "Signs"
# section): a credit is positive (the community owes the cook), a debit is
# negative (the eater owes the community). Show it to a person only through
# BalanceDisplayHelper#charge_amount_tag, never as a raw signed number.
class MealCharge < ApplicationRecord
  KINDS = %w[credit debit guest_debit].freeze

  # What each kind reads as on the statement pages.
  KIND_LABELS = { 'credit' => 'Cooked', 'debit' => 'Attended', 'guest_debit' => 'Guest' }.freeze

  # Ransack allowlist for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id meal_id resident_id kind amount multiplier unit_cost bill_amount created_at updated_at]
  end

  belongs_to :meal
  belongs_to :resident

  # Line items are read by reconciliation, and a reconciliation reaches them
  # through its meals — the meal is the only thing that says which settlement
  # a charge belongs to.
  scope :for_reconciliation, lambda { |reconciliation|
    joins(:meal).where(meals: { reconciliation_id: reconciliation })
  }

  validates :kind, inclusion: { in: KINDS }
  validates :amount, :unit_cost, presence: true, numericality: true

  # Immutable once written, the same as the balances these add up to. The
  # database trigger in 20260802120000 is the backstop; this is the
  # readable half.
  include AppendOnly

  append_only update_message: 'Settlement line items record what a meal cost and who was charged for it. ' \
                              'They cannot be modified — corrections settle in the next reconciliation.',
              destroy_message: 'Settlement line items record what a meal cost and who was charged for it. ' \
                               'They cannot be destroyed.'

  def credit?
    kind == 'credit'
  end

  # True when the cook spent more than the cap allowed, so they were credited
  # less than they laid out and the difference was absorbed rather than
  # charged to the eaters.
  def subsidized?
    bill_amount = self.bill_amount
    return false unless credit? && bill_amount

    T.must(amount) < bill_amount
  end
end

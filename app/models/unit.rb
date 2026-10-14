# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: units
#
#  id           :bigint           not null, primary key
#  name         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_units_on_name  (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

class Unit < ApplicationRecord
  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id created_at name updated_at]
  end

  # A unit with residents can never be deleted. Old bills and meals show the
  # unit's name forever, and every resident (active or not) must keep a unit.
  # To retire a unit, mark its residents inactive — it then drops out of the
  # hosts dropdown on its own. Only an empty unit, one created by mistake,
  # can be destroyed.
  has_many :residents, dependent: :restrict_with_error
  # The settlement lines that name this unit as a person's unit on the day
  # the settlement was made (ADR 0011 rule 7). A settlement keeps them, so
  # a unit a settlement names stays, even with nobody living in it now.
  has_many :reconciliation_balances, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true

  after_destroy :note_live_update
  after_save :note_live_update

  # DERIVED DATA
  # The sum of the cached balances (Resident#balance) of the people who
  # live in it now, so the unit page and each resident's page always agree.
  # The people who have moved out are in no unit's balance (ADR 0011 rule
  # 7): moved_out_balance is theirs, and the units and it add up to $0.00.
  # Signed: positive means the community owes this unit, negative means the
  # unit owes the community (the MealLedger sign convention). Show it to a
  # person only through BalanceDisplayHelper#balance_tag, never as a raw
  # signed number.
  def balance
    # select, not the `active` scope: the units page loads every unit's
    # residents in one query (goldiloader), and a scope would query again.
    residents.select(&:active).reduce(BigDecimal('0')) { |sum, resident| sum + resident.balance }
  end

  # The cached balances of everyone who has moved out, together.
  def self.moved_out_balance
    # NUMERIC, so a BigDecimal (zero with no rows too).
    ResidentBalance.joins(:resident).where(residents: { active: false }).sum(:amount)
  end

  private

  # A unit's name is part of every resident's display name ("Unit A -
  # Alice"), in the hosts dropdown, on the meal page and on calendar
  # chips. A rename touches zero Resident rows, so the unit pushes the
  # residents channel itself. See LiveUpdate.
  def note_live_update
    return unless destroyed? || saved_change_to_name?

    LiveUpdate.residents
  end
end

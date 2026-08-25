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

  validates :name, uniqueness: true

  after_destroy :note_live_update
  after_save :note_live_update

  # DERIVED DATA
  # Signed: positive means the community owes this unit, negative means the
  # unit owes the community (the MealLedger sign convention). Show it to a
  # person only through BalanceDisplayHelper#balance_tag, never as a raw
  # signed number.
  def balance
    return BigDecimal('0') if Meal.unreconciled.none?

    residents.reduce(BigDecimal('0')) { |sum, resident| sum + resident.balance }
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

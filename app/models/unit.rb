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
  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id community_id created_at name updated_at]
  end

  has_many :residents, dependent: :destroy
  belongs_to :community

  validates :name, uniqueness: true

  after_commit :notify_residents_update

  # DERIVED DATA
  def balance
    return BigDecimal('0') if Meal.unreconciled.none?

    residents.reduce(BigDecimal('0')) { |sum, resident| sum + resident.balance }
  end

  def meals_cooked
    return 0 if Meal.unreconciled.none?

    residents.reduce(0) { |sum, resident| sum + resident.bills.joins(:meal).merge(Meal.unreconciled).count }
  end

  def number_of_occupants
    residents.count
  end

  private

  # Notify connected clients that the community hosts list may have changed.
  # CommunitiesController#hosts plucks `units.name` for both the dropdown
  # label ("Unit A - Alice") and the result ordering, so a rename must
  # invalidate the centralized MobX host cache just like a Resident change.
  # Resident#notify_residents_update does not cover this: a Unit rename
  # touches zero Resident rows.
  def notify_residents_update
    return unless destroyed? || saved_change_to_name?

    Pusher.trigger(
      "community-#{community_id}-residents",
      'update',
      { message: 'unit updated' }
    )
  rescue StandardError => e
    Rails.logger.warn("Pusher.trigger failed in Unit#notify_residents_update: #{e.class}: #{e.message}")
    nil
  end
end

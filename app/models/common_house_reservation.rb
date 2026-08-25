# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_reservations
#
#  id           :bigint           not null, primary key
#  end_date     :datetime         not null
#  start_date   :datetime         not null
#  title        :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_common_house_reservations_on_resident_id  (resident_id)
#  index_common_house_reservations_on_start_date   (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (resident_id => residents.id)
#

class CommonHouseReservation < ApplicationRecord
  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id created_at end_date resident_id start_date title updated_at]
  end

  belongs_to :resident

  validates :start_date, presence: true
  validates :end_date, presence: true

  validate :period_is_free
  validate :start_date_is_before_end_date

  after_destroy :note_live_update
  after_save :note_live_update

  def period_is_free
    errors.add(:base, 'Time period is already taken') if CommonHouseReservation
                                                         .where.not(id: id)
                                                         .where(start_date: ...end_date)
                                                         .exists?(['end_date > ?', start_date])
  end

  def start_date_is_before_end_date
    return if start_date.blank? || end_date.blank?

    errors.add(:base, 'Start time must occur before end time') if end_date < start_date
  end

  # Reservations appear on the calendar: every month from start to end
  # (an overnight booking can cross a month), and, after a date change,
  # the months of the old range too. See LiveUpdate.
  def note_live_update
    LiveUpdate.calendar_range(start_date, end_date)
    return unless saved_change_to_start_date? || saved_change_to_end_date?

    LiveUpdate.calendar_range(saved_changes.dig('start_date', 0) || start_date,
                              saved_changes.dig('end_date', 0) || end_date)
  end
end

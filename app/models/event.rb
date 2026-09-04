# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: events
#
#  id           :bigint           not null, primary key
#  allday       :boolean          default(FALSE), not null
#  description  :string           default(""), not null
#  end_date     :datetime
#  start_date   :datetime         not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_events_on_start_date  (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

class Event < ApplicationRecord
  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id allday created_at description end_date start_date title updated_at]
  end

  validates :title, presence: true
  validates :start_date, presence: true

  validate :end_date_or_allday
  validate :start_date_is_before_end_date

  after_destroy :note_live_update
  after_save :note_live_update

  def end_date_or_allday
    return if end_date.present? || allday

    errors.add(:base, 'Event must end or be all day')
  end

  def start_date_is_before_end_date
    start_date = self.start_date
    end_date = self.end_date
    return if allday || end_date.nil? || start_date.nil?

    errors.add(:base, 'Start time must occur before end time') if end_date < start_date
  end

  # Events appear on the calendar: every month from start to end, and,
  # after a date change, every month of the old range too. See
  # LiveUpdate.
  def note_live_update
    LiveUpdate.calendar_range(start_date, end_date)
    return unless saved_change_to_start_date? || saved_change_to_end_date?

    LiveUpdate.calendar_range(saved_changes.dig('start_date', 0) || start_date,
                              saved_changes.dig('end_date', 0) || end_date)
  end
end

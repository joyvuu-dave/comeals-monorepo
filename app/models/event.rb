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
  # NOT NULL, so without this a nil would reach the database as a 500
  # (#139). Nothing sends one today: the API reads all_day as true or
  # false (TrueOrFalse), and the admin box sends 0 or 1.
  validates :allday, inclusion: { in: [true, false], message: TrueOrFalse::MESSAGE }
  validates :start_date, presence: true
  validates :start_date, :end_date, storable_time: true

  validate :end_date_or_allday
  validate :start_date_is_before_end_date

  after_destroy :note_live_update
  after_save :note_live_update

  def end_date_or_allday
    return if end_date.present? || allday

    errors.add(:base, 'Event must end or be all day')
  end

  # An event must end after it starts. An end before the start is refused
  # on every save.
  #
  # An event that ends when it starts lasts zero minutes, so it is refused too,
  # but only when the times are set or changed (#141). A copy of
  # production from September 2026 has three events from before that rule
  # that end when they start, not at midnight: 143, 489 and 1056. Until
  # the deploy, production can save more. The edit forms send the stored
  # times back with every save, so a check on every save would refuse a
  # new title on them. Turning all day off counts as a change, because it
  # makes the times count.
  #
  # The one exception is midnight to midnight in the community's zone: the
  # API saves that when both time menus are empty, for a notice ("Movie
  # night is cancelled tonight"). The rule is here, not in the API, so the
  # admin forms and a task get it too.
  def start_date_is_before_end_date
    start_date = self.start_date
    end_date = self.end_date
    return if allday || end_date.nil? || start_date.nil?
    return if start_date < end_date
    return if start_date == end_date && !times_set_or_changed?
    return if start_date == end_date && T.must(community).midnight?(start_date)

    errors.add(:base, 'Start time must occur before end time')
  end

  # Events appear on the calendar: every month from start to end, and,
  # after a date change, every month of the old range too. An end that
  # did not change is read as it is now, so when nothing moved the old
  # range is the new one, and LiveUpdate notes each month once. See
  # LiveUpdate.
  def note_live_update
    LiveUpdate.calendar_range(start_date, end_date)
    LiveUpdate.calendar_range(saved_changes.dig('start_date', 0) || start_date,
                              saved_changes.dig('end_date', 0) || end_date)
  end

  private

  # Whether this save sets or changes the times. A new event sets them
  # (from nothing), so this is true on create.
  def times_set_or_changed?
    will_save_change_to_start_date? || will_save_change_to_end_date? || will_save_change_to_allday?
  end
end

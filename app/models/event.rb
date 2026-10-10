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
  include ConstraintMessages

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

  END_BEFORE_START = 'Start time must occur before end time'
  SAME_DAY = 'An event must start and end on the same day.'

  # The words for each database rule on this table (ConstraintMessages).
  CONSTRAINT_MESSAGES = {
    'events_end_not_before_start' => END_BEFORE_START,
    'events_one_day' => SAME_DAY
  }.freeze

  validate :end_date_or_allday
  validate :start_date_is_before_end_date
  validate :starts_and_ends_on_one_day

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

    errors.add(:base, END_BEFORE_START)
  end

  # An event must start and end on the same day, in the community's zone
  # (#154). The app's forms give an event one day and two times, and the
  # edit form keeps only the start day, so it cannot save an event that
  # ends on a later day. Admin, a task or the console could make one, so
  # the rule is here, where all of them save. A notice, from midnight to
  # the same midnight, is one day. An event that ends at the next
  # midnight ends on the next day. An all-day event has no end that
  # counts. The database refuses a write of such times too, from any path
  # (events_one_day, a trigger that reads the day in the same zone).
  #
  # The rule runs on every save: no event in production breaks it. If an
  # admin changes the community's zone, an event can end on a later day
  # in the new zone, and then each save of it is refused until its times
  # are changed.
  def starts_and_ends_on_one_day
    start_date = self.start_date
    end_date = self.end_date
    return if allday || start_date.nil? || end_date.nil?

    community = T.must(self.community)
    errors.add(:base, SAME_DAY) unless community.date_of(start_date) == community.date_of(end_date)
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

  def constraint_messages
    CONSTRAINT_MESSAGES
  end

  # Whether this save sets or changes the times. A new event sets them
  # (from nothing), so this is true on create.
  def times_set_or_changed?
    will_save_change_to_start_date? || will_save_change_to_end_date? || will_save_change_to_allday?
  end
end

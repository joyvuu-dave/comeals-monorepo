# typed: true
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
  include ConstraintMessages

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id created_at end_date resident_id start_date title updated_at]
  end

  belongs_to :resident

  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :start_date, :end_date, storable_time: true

  END_BEFORE_START = 'Start time must occur before end time'
  TAKEN = 'Time period is already taken'
  SAME_DAY = 'A booking must start and end on the same day.'

  # The words for each database rule on this table (ConstraintMessages).
  CONSTRAINT_MESSAGES = {
    'common_house_reservations_end_not_before_start' => END_BEFORE_START,
    'common_house_reservations_no_overlap' => TAKEN,
    'common_house_reservations_one_day' => SAME_DAY
  }.freeze

  validate :period_is_free
  validate :start_date_is_before_end_date
  validate :starts_and_ends_on_one_day

  after_destroy :note_live_update
  after_save :note_live_update

  # Whether another booking holds any of this one's time. Two bookings
  # overlap when each starts before the other ends, so one that ends as
  # the other starts is free.
  #
  # A booking that ends when it starts holds no time, so it overlaps
  # nothing: a midnight notice, or one of the old rows from before #141.
  # This checks nothing for such a booking, and leaves out the others.
  # The database's EXCLUDE (common_house_reservations_no_overlap) gives
  # the same answer, because it sees such a booking as an empty range
  # (#149). spec/db/common_house_reservations_no_overlap_spec.rb checks
  # that the two agree. An end before the start is left to
  # start_date_is_before_end_date.
  #
  # The query cannot run with a time the database cannot store:
  # PostgreSQL refuses the whole statement. The storable_time rule above
  # reports such a time, and a missing one is left to the presence rules.
  def period_is_free
    start_date = self.start_date
    end_date = self.end_date
    return unless start_date && end_date && StorableTime.timestamp?(start_date) && StorableTime.timestamp?(end_date)
    return unless start_date < end_date

    errors.add(:base, TAKEN) if CommonHouseReservation
                                .where.not(id: id)
                                .where(start_date: ...end_date)
                                .where('end_date > start_date')
                                .exists?(['end_date > ?', start_date])
  end

  # A booking must end after it starts. An end before the start is
  # refused on every save.
  #
  # A booking that ends when it starts lasts zero minutes, so it would stop no
  # one from booking the common house. It is refused too, but only when
  # the times are set or changed (#141). A copy of production from
  # September 2026 has one booking from before that rule that ends when it
  # starts, not at midnight: 1117. Until the deploy, production can save
  # more. The edit forms send the stored times back with every save, so a
  # check on every save would refuse a new title on it.
  #
  # The one exception is midnight to midnight in the community's zone: the
  # API saves that when both time menus are empty, for a notice ("Movie
  # night is cancelled tonight"). The rule is here, not in the API, so the
  # admin form and a task get it too.
  def start_date_is_before_end_date
    start_date = self.start_date
    end_date = self.end_date
    return if start_date.nil? || end_date.nil?
    return if start_date < end_date
    return if start_date == end_date && !times_set_or_changed?
    return if start_date == end_date && T.must(community).midnight?(start_date)

    errors.add(:base, END_BEFORE_START)
  end

  # A booking must start and end on the same day, in the community's
  # zone (#154). The app's forms give a booking one day and two times,
  # and the edit form keeps only the start day, so it cannot save a
  # booking that ends on a later day. Admin, a task or the console could
  # make one, so the rule is here, where all of them save. A notice, from
  # midnight to the same midnight, is one day. A booking that ends at the
  # next midnight ends on the next day. The database refuses a write of
  # such times too, from any path (common_house_reservations_one_day, a
  # trigger that reads the day in the same zone).
  #
  # The rule runs on every save: no booking in production breaks it. If
  # an admin changes the community's zone, a booking can end on a later
  # day in the new zone, and then each save of it is refused until its
  # times are changed.
  def starts_and_ends_on_one_day
    start_date = self.start_date
    end_date = self.end_date
    return if start_date.nil? || end_date.nil?

    community = T.must(self.community)
    errors.add(:base, SAME_DAY) unless community.date_of(start_date) == community.date_of(end_date)
  end

  # Reservations appear on the calendar: every month from start to end,
  # and, after a date change, the months of the old range too. A booking
  # is one day (#154), but a change of the community's zone can leave one
  # that ends on the next day, and so in the next month. An end that did
  # not change is read as it is now, so when nothing moved
  # the old range is the new one, and LiveUpdate notes each month once.
  # See LiveUpdate.
  def note_live_update
    LiveUpdate.calendar_range(start_date, end_date)
    LiveUpdate.calendar_range(saved_changes.dig('start_date', 0) || start_date,
                              saved_changes.dig('end_date', 0) || end_date)
  end

  private

  def constraint_messages
    CONSTRAINT_MESSAGES
  end

  # Whether this save sets or changes the times. A new booking sets them
  # (from nothing), so this is true on create.
  def times_set_or_changed?
    will_save_change_to_start_date? || will_save_change_to_end_date?
  end
end

# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                       :bigint           not null, primary key
#  color                    :string           not null
#  new_rotation_notified_at :datetime
#  place_value              :integer
#  residents_notified       :boolean          default(FALSE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  community_id             :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

class Rotation < ApplicationRecord
  include BelongsToTheCommunity

  # Dropped 2026-08-25 (both were stale copies of the meals; see #start_date).
  # Kept here for one deploy so code that started before the migration ran
  # does not select them (strong_migrations); remove after the next deploy.
  self.ignored_columns += %w[start_date description]

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id color created_at place_value residents_notified updated_at]
  end

  # no_email suppresses the new-rotation notification for auto-created
  # rotations (see Community#auto_create_rotations). When set, the
  # after_create callback marks the rotation as already notified so the
  # rotations:notify_new rake task skips it.
  attr_accessor :no_email

  # dependent: :destroy, not :nullify. A rotation that leaves its meals behind
  # orphans them, and community:create_rotations refuses to run while a meal
  # has no rotation — so a plain nullify quietly broke the nightly task.
  # The guards below only let the cascade run when every meal is untouched,
  # so it can never delete a meal that carries any ledger data.
  # after_remove: the admin form assigns meals with meal_ids=, and the
  # meals it drops are detached with update_all — no Meal callback runs
  # for them, so the rotation notes their months itself.
  has_many :meals, dependent: :destroy, after_remove: :note_meal_removed
  has_many :bills, through: :meals
  has_many :cooks, -> { distinct }, through: :bills, source: :resident

  before_validation :set_color, on: :create
  # All three prepended, for the same reason as Meal's guards (#26): the
  # has_many above registers its destroy cascade first, so without prepend a
  # refused destroy could still delete meals inside an enclosing transaction.
  # prepend inserts at the front, so these run in reverse declaration order:
  # touched check, then tail check, then the date capture — all before any
  # meal is deleted.
  #
  # Deleting rotations is how an admin applies a schedule change before the
  # calendar naturally reaches it: delete the upcoming rotations (newest
  # first) and the nightly task recreates them under the current schedule.
  # The guards make that path safe; they are not only about mistakes.
  before_destroy :capture_meal_dates_for_cache, prepend: true
  before_destroy :reject_destroy_unless_last, prepend: true
  before_destroy :reject_destroy_if_any_meal_touched, prepend: true
  after_save :note_live_update
  after_commit :set_place_value, on: %i[create destroy]
  after_commit :recolor_remaining_rotations, on: :destroy
  after_create_commit :suppress_notification_if_no_email
  validates :color, presence: true

  accepts_nested_attributes_for :meals

  # Calendar chip backgrounds. Each color must pass WCAG AA (4.5:1)
  # with the text color the calendar picks for it (black on light
  # chips, white on dark — eventTextColor in calendar/show.jsx), in
  # BOTH states: as-is, and desaturated 35% for past events. This
  # property is pinned by spec/serializers/calendar_chip_contrast_spec.rb,
  # which also covers the other calendar chip colors (event, guest
  # room, common house, birthday, meal).
  #
  # The red has moved twice. The original #D9443F failed once dimmed
  # (3.7:1 with either text color). The first fix, #C9332E, passed
  # with room to spare but looked visibly darker than what residents
  # were used to. #D53E3A is the closest passing red to the original:
  # a search over the full RGB neighborhood, ranked by OKLab distance,
  # picked it (4.6:1 base, 6.2:1 dimmed, white text). Side by side it
  # is at the edge of what eyes can tell apart from #D9443F.
  COLORS = ['#3DC656', '#009EDC', '#D53E3A', '#FFC857', '#E9724C'].freeze

  def set_color
    last_color = Rotation.order(:id).pluck(:color).last
    last_index = last_color && COLORS.index(last_color)
    self.color = if last_index
                   COLORS.fetch((last_index + 1) % COLORS.length)
                 else
                   COLORS.fetch(0)
                 end
  end

  def self.recolor_community
    changed_rotation_ids = []
    Rotation.order(:id).each_with_index do |rotation, index|
      new_color = COLORS[index % COLORS.length]
      next if rotation.color == new_color

      # update!, not update_column: the color is on the calendar, so the
      # save has to move updated_at (the month's cache version) and note the
      # meals' months in LiveUpdate. A bare column write did neither, and a
      # month built while the delete committed stayed stale for an hour.
      rotation.update!(color: new_color)
      changed_rotation_ids << rotation.id
    end
    changed_rotation_ids
  end

  # The date of the rotation's first meal, read from the meals every time.
  # This used to be a column filled in the rotation's own after_save, so it
  # kept the old date when a meal was deleted or moved (a meal write does
  # not save the rotation). Derived, it cannot be stale.
  def start_date
    meals.minimum(:date)
  end

  # Rotations whose first meal falls inside `range`. What residents:notify
  # asks; a subquery on meals, since start_date is not a column.
  def self.starting_within(range)
    first_dates = Meal.group(:rotation_id).having('MIN(meals.date) >= ? AND MIN(meals.date) < ?', range.begin,
                                                  range.end)
    where(id: first_dates.select(:rotation_id))
  end

  # The date range shown wherever a rotation is named (the SPA's rotation
  # modal, admin's Period column, the rotation emails). Derived for the
  # same reason as start_date. Format lives in DateRangeDescription.
  def description
    DateRangeDescription.for(meals.minimum(:date), meals.maximum(:date))
  end
  alias date_range_description description

  delegate :count, to: :meals, prefix: true

  # Renumbers every rotation. The number is the calendar chip's title
  # ("Rotation 5", RotationSerializer), so a rotation whose number
  # changed is a calendar change: its updated_at moves, which changes the
  # months' cache version, and its meals' months are pushed. Rotations
  # whose number did not change are left alone.
  def set_place_value
    renumbered = []
    ordered = Rotation.left_joins(:meals).group('rotations.id')
                      .order(Arel.sql('MIN(meals.date) NULLS LAST'), :id)
                      .pluck(:id, :place_value)
    ordered.each_with_index do |(rot_id, place_value), index|
      next if place_value == index + 1

      Rotation.where(id: rot_id).update_all(place_value: index + 1, updated_at: Time.current)
      renumbered << rot_id
    end
    return if renumbered.empty?

    LiveUpdate.batch do
      Meal.where(rotation_id: renumbered).distinct.pluck(:date).each { |date| LiveUpdate.calendar(date) }
    end
  end

  # Rotations appear as colored bars on the calendar, one per meal date.
  # A direct query, not the `meals` association, so the association proxy
  # is not loaded here. See LiveUpdate.
  def note_live_update
    Meal.where(rotation_id: id).distinct.pluck(:date).each { |date| LiveUpdate.calendar(date) }
  end

  def note_meal_removed(meal)
    LiveUpdate.calendar(meal.date)
  end

  # Mark auto-created rotations as already notified so the
  # rotations:notify_new rake task skips them.
  def suppress_notification_if_no_email
    update_column(:new_rotation_notified_at, Time.current) if no_email
  end

  # A meal is "touched" when deleting it would erase something real: it
  # already happened (or is happening today), it is closed or reconciled, or
  # anyone signed up, cooked, or brought a guest. A rotation with any touched
  # meal refuses to die; everything else about it is regenerable data.
  def touched_meals
    meals.where(closed: true)
         .or(meals.where.not(reconciliation_id: nil))
         .or(meals.where(date: ..T.must(community).today))
         .or(meals.where(id: Bill.select(:meal_id)))
         .or(meals.where(id: MealResident.select(:meal_id)))
         .or(meals.where(id: Guest.select(:meal_id)))
  end

  private

  def reject_destroy_if_any_meal_touched
    return unless touched_meals.exists?

    errors.add(:base, 'This rotation has meals that already happened, are closed or reconciled, ' \
                      'or have attendees, cooks, or guests. Only an untouched upcoming rotation ' \
                      'can be deleted.')
    throw :abort
  end

  # Only the last rotation (by meal date) may be deleted. The nightly task
  # only adds meals after the last existing one, so deleting a rotation in
  # the middle would leave a hole in the calendar that nothing ever refills.
  # Deleting newest-first is always possible instead.
  def reject_destroy_unless_last
    last_date = meals.maximum(:date)
    return if last_date.nil?
    return unless T.must(community).meals.exists?(date: (last_date + 1)..)

    errors.add(:base, 'Meals exist after this rotation, and new meals are only ever added after ' \
                      'the last one — deleting from the middle would leave a permanent hole. ' \
                      'Delete the newest rotation first.')
    throw :abort
  end

  def capture_meal_dates_for_cache
    @meal_dates_before_destroy = Meal.where(rotation_id: id).distinct.pluck(:date)
  end

  def recolor_remaining_rotations
    changed_ids = self.class.recolor_community

    dates = @meal_dates_before_destroy || []
    dates |= Meal.where(rotation_id: changed_ids).distinct.pluck(:date) if changed_ids.any?

    LiveUpdate.batch { dates.each { |date| LiveUpdate.calendar(date) } }
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                       :bigint           not null, primary key
#  color                    :string           not null
#  description              :string           default(""), not null
#  new_rotation_notified_at :datetime
#  place_value              :integer
#  residents_notified       :boolean          default(FALSE), not null
#  start_date               :date
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  community_id             :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

class Rotation < ApplicationRecord
  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id color community_id created_at description place_value residents_notified start_date updated_at]
  end

  # no_email suppresses the new-rotation notification for auto-created
  # rotations (see Community#auto_create_rotations). When set, the
  # after_create callback marks the rotation as already notified so the
  # rotations:notify_new rake task skips it.
  attr_accessor :no_email

  belongs_to :community
  # dependent: :destroy, not :nullify. A rotation that leaves its meals behind
  # orphans them, and community:create_rotations refuses to run while a meal
  # has no rotation — so a plain nullify quietly broke the nightly task.
  # The guards below only let the cascade run when every meal is untouched,
  # so it can never delete a meal that carries any ledger data.
  has_many :meals, dependent: :destroy
  has_many :bills, through: :meals
  has_many :cooks, -> { distinct }, through: :bills, source: :resident
  has_many :residents, -> { where(active: true, can_cook: true).where(multiplier: 2..) }, through: :community

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
  after_save :set_description
  after_save :set_start_date
  after_commit :set_place_value, on: %i[create destroy]
  after_commit :invalidate_calendar_cache
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
    self.color = if last_color && COLORS.include?(last_color)
                   COLORS[(COLORS.index(last_color) + 1) % COLORS.length]
                 else
                   COLORS[0]
                 end
  end

  def self.recolor_community
    changed_rotation_ids = []
    Rotation.order(:id).each_with_index do |rotation, index|
      new_color = COLORS[index % COLORS.length]
      next if rotation.color == new_color

      rotation.update_column(:color, new_color)
      changed_rotation_ids << rotation.id
    end
    changed_rotation_ids
  end

  def set_description
    update_columns(description: date_range_description)
  end

  # The date range shown wherever a rotation is named (the SPA's rotation
  # modal, admin's Period column). Format lives in DateRangeDescription.
  def date_range_description
    DateRangeDescription.for(meals.minimum(:date), meals.maximum(:date))
  end

  def set_start_date
    update_columns(start_date: meals.order(:date).first&.date)
  end

  delegate :count, to: :meals, prefix: true

  def set_place_value
    Rotation.order(:start_date, :id)
            .pluck(:id)
            .each_with_index do |rot_id, index|
      Rotation.where(id: rot_id).update_all(place_value: index + 1)
    end
  end

  def invalidate_calendar_cache
    # Rotations appear as colored bars on the calendar.
    # See CalendarSerializer for the full cache invalidation contract.
    # Uses a direct DB query (not `meals` association) to avoid eagerly
    # loading and tainting the association proxy.
    Meal.where(rotation_id: id).distinct.pluck(:date).each do |date|
      community.invalidate_calendar_cache(date)
    end
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
         .or(meals.where(date: ..Time.zone.today))
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
    return unless community.meals.exists?(date: (last_date + 1)..)

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

    dates.each { |date| community.trigger_pusher(date) }
  end
end

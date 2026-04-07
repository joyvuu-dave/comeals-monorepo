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
# Indexes
#
#  index_rotations_on_community_id  (community_id)
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
  has_many :meals, dependent: :nullify
  has_many :bills, through: :meals
  has_many :cooks, -> { distinct }, through: :bills, source: :resident
  has_many :residents, -> { where(active: true, can_cook: true).where(multiplier: 2..) }, through: :community

  before_validation :set_color, on: :create
  before_destroy :capture_meal_dates_for_cache
  after_save :set_description
  after_save :set_start_date
  after_commit :set_place_value, on: %i[create destroy]
  after_commit :invalidate_calendar_cache
  after_commit :recolor_remaining_rotations, on: :destroy
  after_create_commit :suppress_notification_if_no_email
  validates :color, presence: true

  accepts_nested_attributes_for :meals

  COLORS = ['#3DC656', '#009EDC', '#D9443F', '#FFC857', '#E9724C'].freeze

  def set_color
    last_color = Rotation.where(community_id: community_id).order(:id).pluck(:color).last
    self.color = if last_color && COLORS.include?(last_color)
                   COLORS[(COLORS.index(last_color) + 1) % COLORS.length]
                 else
                   COLORS[0]
                 end
  end

  def self.recolor_community(community_id)
    changed_rotation_ids = []
    Rotation.where(community_id: community_id).order(:id).each_with_index do |rotation, index|
      new_color = COLORS[index % COLORS.length]
      next if rotation.color == new_color

      rotation.update_column(:color, new_color)
      changed_rotation_ids << rotation.id
    end
    changed_rotation_ids
  end

  def set_description
    ordered = meals.order(:date)
    update_columns(description: "#{ordered.first&.date} to #{ordered.last&.date}")
  end

  def set_start_date
    update_columns(start_date: meals.order(:date).first&.date)
  end

  delegate :count, to: :meals, prefix: true

  def set_place_value
    Rotation.where(community_id: community_id)
            .order(:start_date, :id)
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

  private

  def capture_meal_dates_for_cache
    @meal_dates_before_destroy = Meal.where(rotation_id: id).distinct.pluck(:date)
  end

  def recolor_remaining_rotations
    changed_ids = self.class.recolor_community(community_id)

    dates = @meal_dates_before_destroy || []
    dates |= Meal.where(rotation_id: changed_ids).distinct.pluck(:date) if changed_ids.any?

    dates.each { |date| community.trigger_pusher(date) }
  end
end

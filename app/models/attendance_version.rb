# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: attendance_versions
#
#  id          :bigint           not null, primary key
#  version     :bigint           not null
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_attendance_versions_on_meal_id_and_resident_id  (meal_id,resident_id) UNIQUE
#  index_attendance_versions_on_resident_id              (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id) ON DELETE => cascade
#  fk_rails_...  (resident_id => residents.id) ON DELETE => cascade
#
# How many writes there have been to one person's attendance on one meal.
# The database trigger comeals_count_attendance_version adds one on every
# insert, update and delete of their meal_residents row, whatever made the
# write. The app only reads this table.
#
# The meal form shows each person's version, and an attendance write from
# the meal page sends the version it expects (public/api.md, "The
# attendance version").
# Api::V1::MealsController refuses a write built on another version, so a
# request that reaches the server after a newer one, or after the page
# gave up on it, writes nothing.
#
# The row records how many writes there were, not money (money rule 8).
class AttendanceVersion < ApplicationRecord
  extend T::Sig

  belongs_to :meal
  belongs_to :resident

  # A person with no row has had no write since the table was made.
  NONE = 0

  # Only the trigger writes a row, so the app can never count a write
  # twice or set a number by hand.
  sig { returns(T::Boolean) }
  def readonly?
    true
  end

  # The version of each person's attendance on this meal, by resident id.
  # A person missing from the hash has version 0. It takes the meal's id,
  # so it can be read before the meal is loaded.
  sig { params(meal_id: T.untyped).returns(T::Hash[Integer, Integer]) }
  def self.by_resident_id(meal_id)
    where(meal_id: meal_id).pluck(:resident_id, :version).to_h
  end

  sig { params(meal: Meal, resident_id: Integer).returns(Integer) }
  def self.of(meal, resident_id)
    where(meal_id: meal.id, resident_id: resident_id).pick(:version) || NONE
  end
end

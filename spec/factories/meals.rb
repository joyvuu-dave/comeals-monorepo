# frozen_string_literal: true

# == Schema Information
#
# Table name: meals
#
#  id                :bigint           not null, primary key
#  cancelled_at      :datetime
#  cap               :decimal(12, 8)
#  closed            :boolean          default(FALSE), not null
#  closed_at         :datetime
#  date              :date             not null
#  description       :text             default(""), not null
#  max               :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  community_id      :bigint           not null
#  reconciliation_id :bigint
#  rotation_id       :bigint           not null
#
# Indexes
#
#  index_meals_on_date               (date) UNIQUE
#  index_meals_on_reconciliation_id  (reconciliation_id)
#  index_meals_on_rotation_id        (rotation_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (rotation_id => rotations.id)
#

# The date a meal gets when a spec does not give one. The first such meal
# in an example gets the date `newest` days ago, and each next one a day
# further back, up to days_back dates in all. After that the dates start
# again at `newest`.
#
# meals.date is unique, so a meal on a date that another meal has fails
# with "Date has already been taken". Two rules keep a default date from
# doing that at random:
#
# 1. A default meal never gets a date that a meal in the database already
#    has. The factory skips that date and takes the next one. So a spec
#    can give one meal a date and then make meals with no date.
# 2. The count starts again before every example
#    (spec/support/default_meal_date.rb). So the default dates of an
#    example are the same on every run, whatever specs ran before it. A
#    spec that makes a meal with no date and then gives another meal that
#    same date fails on every run, not once in 730 runs. Give the first
#    meal a date too.
#
# `newest` is the age of the latest cutoff a settlement may have today
# (Reconciliation::DAYS_TO_WAIT, ADR 0011 rule 2), so settle! with no
# cutoff claims every default meal. A newer meal would have to wait, and
# settle! would leave it out.
#
# days_back limits how far back a default meal goes. A price is read on
# the meal's date, and the resident factory counts a child's birthday
# back from today (8 years for half price). So on a meal more than three
# years back that child is under 5 and eats free (#117).
# spec/models/factories_spec.rb checks the price bands at both ends of
# this window.
#
# Methods, not a constant: factory_bot_rails loads this file again on
# every code reload, and a constant would warn each time.
module DefaultMealDate
  def self.days_back = 730

  def self.newest = Reconciliation::DAYS_TO_WAIT

  # The date for one value of the count. The first value is 1.
  def self.for(count) = (((count - 1) % days_back) + newest).days.ago.to_date

  # The next date in the cycle that no meal has. The block gives the next
  # value of the count each time it is called, so a skipped date uses up
  # its value. Each date in the window is tried at most once.
  def self.next_free
    days_back.times do
      date = self.for(yield)
      return date unless Meal.exists?(date: date)
    end
    raise "All #{days_back} dates a meal with no date can get already have a meal. Give this meal a date."
  end

  # Start the count again at 1.
  def self.restart = FactoryBot.rewind_sequence(:default_meal_date_count)
end

FactoryBot.define do
  # The count behind DefaultMealDate. A global sequence, not one on the
  # meal factory, because a meal that skips a taken date uses more than
  # one value.
  sequence(:default_meal_date_count)

  factory :meal do
    community
    date { DefaultMealDate.next_free { generate(:default_meal_date_count) } }
    # Every meal belongs to a rotation (#100). A meal made here gets a new
    # rotation of its own unless the spec passes one, so it is never in
    # another meal's rotation by chance: a spec about the meals of one
    # rotation passes that rotation to each meal.
    rotation { association :rotation, community: community }
  end
end

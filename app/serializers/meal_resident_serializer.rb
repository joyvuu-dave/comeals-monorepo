# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_residents
#
#  id           :bigint           not null, primary key
#  community_id :bigint           not null
#  created_at   :datetime         not null
#  late         :boolean          default(FALSE), not null
#  meal_id      :bigint           not null
#  multiplier   :integer          not null
#  resident_id  :bigint           not null
#  updated_at   :datetime         not null
#  vegetarian   :boolean          default(FALSE), not null
#

class MealResidentSerializer < ActiveModel::Serializer
  attributes :id,
             :meal_id,
             :resident_id,
             :late,
             :vegetarian,
             :created_at
end

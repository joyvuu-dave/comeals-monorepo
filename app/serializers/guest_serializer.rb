# frozen_string_literal: true

# == Schema Information
#
# Table name: guests
#
#  id          :bigint           not null, primary key
#  created_at  :datetime         not null
#  late        :boolean          default(FALSE), not null
#  meal_id     :bigint           not null
#  multiplier  :integer          default(2), not null
#  name        :string           default(""), not null
#  resident_id :bigint           not null
#  updated_at  :datetime         not null
#  vegetarian  :boolean          default(FALSE), not null
#

class GuestSerializer < ActiveModel::Serializer
  attributes :id,
             :meal_id,
             :resident_id,
             :name,
             :vegetarian,
             :created_at
end

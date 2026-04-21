# frozen_string_literal: true

# == Schema Information
#
# Table name: units
#
#  id           :bigint           not null, primary key
#  name         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_units_on_name  (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

FactoryBot.define do
  factory :unit do
    community
    sequence(:name) { |n| "Unit #{n}" }
  end
end

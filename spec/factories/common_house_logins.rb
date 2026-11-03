# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_logins
#
#  id               :bigint           not null, primary key
#  keys_valid_since :datetime         not null
#  password_digest  :string           not null
#  singleton_guard  :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_common_house_logins_on_singleton_guard  (singleton_guard) UNIQUE
#
FactoryBot.define do
  factory :common_house_login do
    password { 'a long shared password' }
  end
end

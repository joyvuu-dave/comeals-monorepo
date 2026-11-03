# frozen_string_literal: true

FactoryBot.define do
  factory :common_house_login do
    password { 'a long shared password' }
  end
end

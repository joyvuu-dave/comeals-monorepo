# frozen_string_literal: true

class GuestSerializer
  include Alba::Resource

  attributes :id,
             :meal_id,
             :resident_id,
             :vegetarian,
             :created_at
end

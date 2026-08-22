# frozen_string_literal: true

class MealResidentSerializer
  include Alba::Resource

  attributes :id,
             :meal_id,
             :resident_id,
             :late,
             :vegetarian,
             :created_at
end

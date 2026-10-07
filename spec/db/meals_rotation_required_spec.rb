# frozen_string_literal: true

require 'rails_helper'

# Every meal belongs to a rotation (#100). Meal validates it for writes
# through the model; NOT NULL on meals.rotation_id refuses every write
# that skips the model (update_columns, insert_all, a rake task, psql).
# A meal with no rotation used to stop the nightly EnsureRotationsJob.
RSpec.describe 'meals.rotation_id is required by the database' do
  let(:community) { create(:community) }

  it 'refuses a validation-skipping write that takes a meal out of its rotation' do
    meal = create(:meal, community: community)

    expect { meal.update_columns(rotation_id: nil) }.to raise_error(ActiveRecord::NotNullViolation, /rotation_id/)
  end

  it 'refuses a raw insert of a meal with no rotation' do
    expect do
      Meal.insert_all([{ community_id: community.id, date: Date.new(2026, 5, 1), rotation_id: nil }])
    end.to raise_error(ActiveRecord::NotNullViolation, /rotation_id/)
  end
end

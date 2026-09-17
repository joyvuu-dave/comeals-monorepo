# frozen_string_literal: true

require 'rails_helper'

# closed_at is the "extras" boundary: an attendance row created after it
# may back out of a closed meal (ClosedMealAttendanceFreeze). Meal's
# before_save keeps closed and closed_at in step for writes through the
# model; this CHECK catches every write path that skips the model
# (update_all, update_columns, rake tasks, psql). Without it a closed
# meal with no timestamp would trap every extra on it for good.
RSpec.describe 'meals closed_at matches closed check constraint' do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }

  it 'refuses a validation-skipping write that closes a meal without a timestamp' do
    expect do
      meal.update_columns(closed: true, closed_at: nil)
    end.to raise_error(ActiveRecord::StatementInvalid, /meals_closed_at_matches_closed/)
  end

  it 'refuses a validation-skipping write that leaves a timestamp on an open meal' do
    expect do
      meal.update_columns(closed: false, closed_at: Time.current)
    end.to raise_error(ActiveRecord::StatementInvalid, /meals_closed_at_matches_closed/)
  end

  it 'allows an open meal without a timestamp and a closed meal with one' do
    expect do
      meal.update_columns(closed: true, closed_at: Time.current)
      meal.update_columns(closed: false, closed_at: nil)
    end.not_to raise_error
  end
end

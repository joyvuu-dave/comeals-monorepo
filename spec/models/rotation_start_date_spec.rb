# frozen_string_literal: true

require 'rails_helper'

# rotations.start_date is "the date of the rotation's first meal"
# (Rotation#set_start_date). It is recomputed only in the rotation's own
# after_save. Deleting a meal does not save the rotation, so the column
# keeps the deleted meal's date. residents:notify reads start_date to pick
# the rotations that begin within a week; the calendar chip reads it too.
RSpec.describe Rotation, '#start_date' do
  let(:community) { create(:community) }

  it 'moves to the next meal' do
    rotation = community.rotations.create!(meals_attributes: [{ date: Date.new(2027, 6, 10) },
                                                              { date: Date.new(2027, 6, 17) }])
    first = rotation.meals.order(:date).first
    expect(rotation.reload.start_date).to eq(Date.new(2027, 6, 10))

    first.destroy!

    expect(rotation.reload.start_date).to eq(Date.new(2027, 6, 17))
  end

  it 'moves when the first meal is given a later date' do
    rotation = community.rotations.create!(meals_attributes: [{ date: Date.new(2027, 6, 10) },
                                                              { date: Date.new(2027, 6, 17) }])
    first = rotation.meals.order(:date).first

    first.update!(date: Date.new(2027, 6, 24))

    expect(rotation.reload.start_date).to eq(Date.new(2027, 6, 17))
  end
end

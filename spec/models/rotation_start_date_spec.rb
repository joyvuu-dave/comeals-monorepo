# frozen_string_literal: true

require 'rails_helper'

# Rotation#start_date is the date of the rotation's first meal. It used to
# be a column filled in the rotation's own after_save, and a meal write does
# not save the rotation, so deleting or moving the first meal left the old
# date (invariant hunt, 2026-08-25). It is derived from the meals now; these
# pin that a meal delete or move is seen at once.
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

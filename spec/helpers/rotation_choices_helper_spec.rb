# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RotationChoicesHelper do
  let(:community) { create(:community) }

  describe '#rotation_choices' do
    # The script in active_admin.js compares the data attributes with the
    # date field's value, so they are ISO dates, like the field.
    it 'names each rotation by its number and the dates of its first and last meal, newest first' do
      older = create(:rotation, community: community)
      create(:meal, community: community, rotation: older, date: Date.new(2027, 1, 24))
      create(:meal, community: community, rotation: older, date: Date.new(2027, 1, 10))
      newer = create(:rotation, community: community)
      create(:meal, community: community, rotation: newer, date: Date.new(2027, 2, 2))
      create(:meal, community: community, rotation: newer, date: Date.new(2027, 3, 4))

      expect(helper.rotation_choices).to eq(
        [
          ['Rotation 2: Feb 2 – Mar 4, 2027', newer.id,
           { 'data-first-date' => '2027-02-02', 'data-last-date' => '2027-03-04' }],
          ['Rotation 1: Jan 10–24, 2027', older.id,
           { 'data-first-date' => '2027-01-10', 'data-last-date' => '2027-01-24' }]
        ]
      )
    end

    # The nightly job makes rotations in date order, so there the newer
    # id has the later meals too. Not always: the rotation made first
    # here has the later meals, and it is listed first.
    # Each rotation is made with its meals, the way the nightly job does
    # it, so the place numbers follow the dates.
    it 'puts the rotation with the later meals first, whatever order the rotations were made in' do
      later = create(:rotation, community: community, meals_attributes: [{ date: Date.new(2027, 3, 4) }])
      earlier = create(:rotation, community: community, meals_attributes: [{ date: Date.new(2027, 1, 10) }])

      expect(helper.rotation_choices.map(&:first)).to eq(['Rotation 2: Mar 4, 2027', 'Rotation 1: Jan 10, 2027'])
      expect(helper.rotation_choices.map(&:second)).to eq([later.id, earlier.id])
    end

    # Two rotations share a place number only when neither has one, which
    # happens only to rows written without the model
    # (Rotation#set_place_value numbers every rotation in the transaction
    # that makes one). Then the newer id comes first. Rows can
    # not show this every time: with equal place numbers, PostgreSQL
    # returns the rows in whatever order its grouping finds them, and an
    # example with two such rotations passed with the id dropped from the
    # ORDER BY (mutant, 2026-10-07). So this reads the statement.
    it 'puts the newer id first when place numbers are equal' do
      create(:rotation, community: community)
      statements = []
      record = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { helper.rotation_choices }

      expect(statements.grep(/FROM "rotations"/).sole)
        .to end_with('ORDER BY "rotations"."place_value" DESC, "rotations"."id" DESC')
    end

    it 'lists a rotation with no meals, with no dates for the script to match' do
      empty = create(:rotation, community: community)

      expect(helper.rotation_choices).to eq(
        [['Rotation 1: no meals', empty.id, { 'data-first-date' => nil, 'data-last-date' => nil }]]
      )
    end
  end
end

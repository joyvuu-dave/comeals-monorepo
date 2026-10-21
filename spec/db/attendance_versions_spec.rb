# frozen_string_literal: true

require 'rails_helper'

# The trigger comeals_count_attendance_version adds one to a person's
# attendance version on a meal for every insert, update and delete of
# their meal_residents row, on every write path: the models (the API and
# admin) and raw SQL (a rake task, psql). The API refuses an attendance
# write built on another version (spec/requests/api/v1/attendance_out_of_order_spec.rb).
RSpec.describe 'the attendance_versions table' do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:alice) { create(:resident, community: community) }
  let(:connection) { ActiveRecord::Base.connection }

  def version(on: meal, of: alice)
    AttendanceVersion.of(on, of.id)
  end

  it 'is 0 for a person whose attendance was never written' do
    expect(version).to eq(0)
    expect(AttendanceVersion.by_resident_id(meal.id)).to eq({})
  end

  it 'counts a sign-up, a change and a take-off made through the model' do
    row = create(:meal_resident, meal: meal, resident: alice, community: community)
    expect(version).to eq(1)

    row.update!(late: true)
    expect(version).to eq(2)

    row.destroy!
    expect(version).to eq(3)
    expect(AttendanceVersion.by_resident_id(meal.id)).to eq(alice.id => 3)
  end

  # A take-off deletes the row. The version stays, so a second sign-up
  # gets a new number, not the one the first sign-up had.
  it 'keeps counting after a take-off, so a sign-up again gets a new number' do
    create(:meal_resident, meal: meal, resident: alice, community: community).destroy!
    create(:meal_resident, meal: meal, resident: alice, community: community)

    expect(version).to eq(3)
  end

  it 'counts writes made with raw SQL' do
    create(:meal_resident, meal: meal, resident: alice, community: community)
    connection.execute("UPDATE meal_residents SET vegetarian = true WHERE resident_id = #{alice.id}")
    connection.execute("DELETE FROM meal_residents WHERE resident_id = #{alice.id}")

    expect(version).to eq(3)
  end

  # Moving a row to another person or meal changes the attendance of
  # both: one loses the row and the other gets it.
  it 'counts a row moved to another person for both of them' do
    bob = create(:resident, community: community)
    create(:meal_resident, meal: meal, resident: alice, community: community)
    connection.execute("UPDATE meal_residents SET resident_id = #{bob.id} WHERE resident_id = #{alice.id}")

    expect(version).to eq(2)
    expect(version(of: bob)).to eq(1)
  end

  it 'counts each person on each meal on its own' do
    bob = create(:resident, community: community)
    other_meal = create(:meal, community: community, date: meal.date + 1)
    create(:meal_resident, meal: meal, resident: alice, community: community)
    create(:meal_resident, meal: meal, resident: bob, community: community)
    create(:meal_resident, meal: other_meal, resident: alice, community: community)

    expect([version, version(of: bob), version(on: other_meal)]).to eq([1, 1, 1])
  end

  it 'goes with its meal when an open meal is deleted' do
    create(:meal_resident, meal: meal, resident: alice, community: community)
    meal.destroy!

    expect(AttendanceVersion.where(meal_id: meal.id)).not_to exist
  end

  it 'refuses a version of 0 or less' do
    expect do
      connection.execute('INSERT INTO attendance_versions (meal_id, resident_id, version) ' \
                         "VALUES (#{meal.id}, #{alice.id}, 0)")
    end.to raise_error(ActiveRecord::StatementInvalid, /attendance_versions_version_positive/)
  end

  it 'cannot be written through the model' do
    create(:meal_resident, meal: meal, resident: alice, community: community)

    expect { AttendanceVersion.find_by!(meal_id: meal.id).update!(version: 9) }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(version).to eq(1)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The admin meal form nests guests, and its permit list includes
# guests_attributes[meal_id] (app/admin/meal.rb). The form fills that
# field with the meal's own id, hidden. But a request can send any id.
#
# For a new guest that changes nothing: has_many build sets the foreign
# key from the owner after the attributes, so the guest lands on the meal
# whose form was posted (the control below pins that).
#
# For an existing guest it moves the row to another meal. That is a
# removal from this meal and an addition to the other, and neither goes
# through the closed-meal freeze (ClosedMealAttendanceFreeze checks
# additions on create and removals on destroy, never an update that
# changes meal_id). So a guest who was on a meal before it closed can be
# taken off it, and a guest can be put on a closed meal with no extras,
# both from the first meal's edit form. The row has to carry resident_id,
# as the form's rows always do: Meal's reject_if drops a nested row
# without one.
#
# The database does not catch this either. LocksItsMealFirst locks both
# meals and the settled-child trigger checks both, but closed is not
# settled, and nothing in the database knows about the freeze.
#
# Lock hunt, 2026-09-21. Found while listing every write to guests.
RSpec.describe 'Admin meal form: a nested guest with another meal_id' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:host) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:meal) { create(:meal, community: community) }
  let(:other_meal) { create(:meal, community: community, date: meal.date + 1) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def submit(guests_attributes)
    patch "/meals/#{meal.id}", params: { meal: { guests_attributes: guests_attributes } }
  end

  it 'puts a new guest on the meal whose form was posted, whatever meal_id says (control)' do
    submit('0' => { multiplier: 2, resident_id: host.id, meal_id: other_meal.id, _destroy: '0' })

    expect(Guest.count).to eq(1)
    expect(Guest.last.meal_id).to eq(meal.id)
  end

  it 'refuses to move a guest off a closed meal when the guest was on it before it closed' do
    guest = create(:guest, meal: meal, resident: host)
    meal.update!(closed: true)

    submit('0' => { id: guest.id, resident_id: host.id, meal_id: other_meal.id })

    expect(guest.reload.meal_id).to eq(meal.id)
    expect(response.body).to include('Meal has been closed.')
  end

  it 'refuses to move a guest onto a closed meal with no extras' do
    guest = create(:guest, meal: meal, resident: host)
    other_meal.update!(closed: true)

    submit('0' => { id: guest.id, resident_id: host.id, meal_id: other_meal.id })

    expect(guest.reload.meal_id).to eq(meal.id)
    expect(response.body).to include('Meal has been closed.')
  end
end

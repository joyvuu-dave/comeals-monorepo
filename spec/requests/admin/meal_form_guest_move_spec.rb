# frozen_string_literal: true

require 'rails_helper'

# The admin meal form nests guests. Until 2026-09-24 its permit list
# included guests_attributes[meal_id], filled by a hidden field with the
# meal's own id, and a hand-made request could send any id: for an
# existing guest that moved the row to another meal, past the closed-meal
# freeze, which checked additions on create and removals on destroy but
# never an update that changed meal_id (lock hunt, 2026-09-21; the two
# examples below were red).
#
# Two fixes, both pinned here. The form no longer permits meal_id, so a
# request that sends one changes nothing (this file). And the freeze
# treats a move as a removal plus an addition, so a write that skips the
# form is refused too (spec/models/guest_spec.rb and
# spec/models/meal_resident_spec.rb, '#move_keeps_both_meals_rules').
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

  it 'leaves an existing guest on the closed meal it was on before it closed, whatever meal_id says' do
    guest = create(:guest, meal: meal, resident: host)
    meal.update!(closed: true)

    submit('0' => { id: guest.id, resident_id: host.id, meal_id: other_meal.id })

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(guest.reload.meal_id).to eq(meal.id)
  end

  it 'leaves an existing guest off a closed meal with no extras, whatever meal_id says' do
    guest = create(:guest, meal: meal, resident: host)
    other_meal.update!(closed: true)

    submit('0' => { id: guest.id, resident_id: host.id, meal_id: other_meal.id })

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(guest.reload.meal_id).to eq(meal.id)
    expect(other_meal.reload.guests).to be_empty
  end
end

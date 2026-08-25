# frozen_string_literal: true

require 'rails_helper'

# The admin meal form nests guests (guests_attributes with _destroy). That
# is a second way to add or remove a guest, next to the API. The API's
# closed-meal rules are pinned in spec/requests/api/v1/meals_controller_spec.rb;
# this file pins the same rules on the form, because a guard the form
# skips is how #73 and #78 happened on other forms.
RSpec.describe 'Admin meal form: nested guests' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:host) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:meal) { create(:meal, community: community) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def submit(guests_attributes)
    patch "/meals/#{meal.id}", params: { meal: { guests_attributes: guests_attributes } }
  end

  it 'adds a guest to an open meal (control)' do
    expect { submit('0' => { multiplier: 2, resident_id: host.id, _destroy: '0' }) }
      .to change(meal.guests, :count).by(1)
  end

  it 'refuses a guest on a closed meal with no extras, and says why' do
    meal.update!(closed: true)

    expect { submit('0' => { multiplier: 2, resident_id: host.id, _destroy: '0' }) }
      .not_to change(Guest, :count)
    expect(response.body).to include('Meal has been closed.')
  end

  it 'refuses a guest on a closed meal whose extras are full' do
    meal.update!(closed: true, max: 1)
    create(:meal_resident, meal: meal, resident: host, community: community, admin_correction: true)

    expect { submit('0' => { multiplier: 2, resident_id: host.id, _destroy: '0' }) }
      .not_to change(Guest, :count)
    expect(response.body).to include('Meal has no open spots.')
  end

  it 'refuses to remove a guest who was on the meal before it closed' do
    guest = create(:guest, meal: meal, resident: host)
    meal.update!(closed: true)

    expect { submit('0' => { id: guest.id, _destroy: '1' }) }
      .not_to change(Guest, :count)
    expect(response.body).to include('Meal has been closed.')
  end

  it 'removes a guest who was added as an extra after the meal closed' do
    meal.update!(closed: true, max: 3)
    guest = create(:guest, meal: meal, resident: host)

    expect { submit('0' => { id: guest.id, _destroy: '1' }) }
      .to change(Guest, :count).by(-1)
  end
end

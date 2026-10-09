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

  # The form's meal comes preloaded with its attendance (scoped_collection),
  # and Rails puts the nested guest into that loaded list before validation,
  # so a count taken from the loaded list included the guest itself and
  # refused the last open spot (review, 2026-09-24).
  it 'adds a guest to a closed meal with exactly one spot open' do
    meal.update!(closed: true, max: 1)

    expect { submit('0' => { multiplier: 2, resident_id: host.id, _destroy: '0' }) }
      .to change(meal.guests, :count).by(1)
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

  it 'refuses a new price for a guest who was on the meal before it closed, and says why' do
    guest = create(:guest, meal: meal, resident: host, multiplier: 2)
    meal.update!(closed: true)

    submit('0' => { id: guest.id, multiplier: 1, resident_id: host.id, _destroy: '0' })

    expect(guest.reload.multiplier).to eq(2)
    expect(response.body).to include('Meal has been closed.')
  end

  # A new host moves the guest's whole charge to another person, so it
  # follows the same rule as a new price.
  it 'refuses a new host for a guest who was on the meal before it closed, and says why' do
    guest = create(:guest, meal: meal, resident: host)
    other_host = create(:resident, community: community, unit: unit)
    meal.update!(closed: true)

    submit('0' => { id: guest.id, multiplier: 2, resident_id: other_host.id, _destroy: '0' })

    expect(guest.reload.resident_id).to eq(host.id)
    expect(response.body).to include('Meal has been closed.')
  end

  # The form's Closed box can come in the same save as a guest's new price
  # or host. The close happens in that save, so every guest already on the
  # meal was there before it, and the change is refused like any other
  # change to an original guest. The guest checks run before
  # Meal#conditionally_set_closed_at sets closed_at (a before_save), so they
  # used to read a nil closed_at and raise (review, 2026-10-09).
  def close_and_change_guest(guest, changes)
    guest_attributes = { id: guest.id, multiplier: guest.multiplier, resident_id: guest.resident_id, _destroy: '0' }
    patch "/meals/#{meal.id}",
          params: { meal: { closed: '1', guests_attributes: { '0' => guest_attributes.merge(changes) } } }
  end

  it 'refuses a new price for a guest in the same save that closes the meal, and says why' do
    guest = create(:guest, meal: meal, resident: host, multiplier: 2)

    close_and_change_guest(guest, multiplier: 1)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Meal has been closed.')
    expect(guest.reload.multiplier).to eq(2)
    expect(meal.reload.closed).to be(false)
  end

  it 'refuses a new host for a guest in the same save that closes the meal, and says why' do
    guest = create(:guest, meal: meal, resident: host)
    other_host = create(:resident, community: community, unit: unit)

    close_and_change_guest(guest, resident_id: other_host.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Meal has been closed.')
    expect(guest.reload.resident_id).to eq(host.id)
    expect(meal.reload.closed).to be(false)
  end

  it 'refuses to remove a guest in the same save that closes the meal, and says why' do
    guest = create(:guest, meal: meal, resident: host)

    close_and_change_guest(guest, _destroy: '1')

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Meal has been closed.')
    expect(Guest.exists?(guest.id)).to be(true)
    expect(meal.reload.closed).to be(false)
  end

  it 'closes the meal when each guest comes back unchanged (control)' do
    guest = create(:guest, meal: meal, resident: host)

    close_and_change_guest(guest, {})

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload.closed).to be(true)
  end

  it 'changes the host of a guest added as an extra after the meal closed' do
    meal.update!(closed: true, max: 3)
    guest = create(:guest, meal: meal, resident: host)
    other_host = create(:resident, community: community, unit: unit)

    submit('0' => { id: guest.id, multiplier: 2, resident_id: other_host.id, _destroy: '0' })

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(guest.reload.resident_id).to eq(other_host.id)
  end

  # The menu offers the only two prices a guest can have (Guest, "the
  # price"), so it always shows the stored one and a save sends it back
  # unchanged. A new guest starts as an adult.
  it 'offers Adult and Child as the price, with Adult first for a new guest' do
    guest = create(:guest, meal: meal, resident: host, multiplier: 1)

    get "/meals/#{meal.id}/edit"

    page = response.parsed_body
    menu = page.at_css("select[name='meal[guests_attributes][0][multiplier]']")
    expect(page.at_css("input[name='meal[guests_attributes][0][id]']")['value']).to eq(guest.id.to_s)
    expect(menu.css('option').map { |option| [option.text, option['value']] })
      .to eq([%w[Adult 2], %w[Child 1]])
    expect(menu.at_css('option[selected]')['value']).to eq('1')

    new_guest = Nokogiri::HTML(page.at_css('.has_many_add')['data-html'])
    new_menu = new_guest.at_css('select[name$="[multiplier]"]')
    expect(new_menu.css('option').map(&:text)).to eq(%w[Adult Child])
    expect(new_menu.at_css('option[selected]')['value']).to eq('2')
  end

  # The form sends every guest back with the price it shows, so a save that
  # changes something else on a closed meal must not be read as a new price.
  it 'saves a new max on a closed meal when each guest comes back with the same price' do
    guest = create(:guest, meal: meal, resident: host, multiplier: 1)
    meal.update!(closed: true)

    same_price = { id: guest.id, multiplier: 1, resident_id: host.id, _destroy: '0' }
    patch "/meals/#{meal.id}", params: { meal: { max: 5, guests_attributes: { '0' => same_price } } }

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload.max).to eq(5)
    expect(guest.reload.multiplier).to eq(1)
  end

  it 'removes a guest who was added as an extra after the meal closed' do
    meal.update!(closed: true, max: 3)
    guest = create(:guest, meal: meal, resident: host)

    expect { submit('0' => { id: guest.id, _destroy: '1' }) }
      .to change(Guest, :count).by(-1)
  end
end

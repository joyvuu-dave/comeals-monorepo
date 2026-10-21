# frozen_string_literal: true

require 'rails_helper'

# A tap on the meal page changes the screen at once and sends one request:
# a sign-up (POST), a take-off (DELETE), or a Late or Veg change (PATCH).
# The page does not wait for one answer before it sends the next tap, and
# two requests can reach the server in the other order. A request can also
# be held on the network for longer than the page waits for it (35 s), so
# it can arrive after the page gave up on it, loaded the meal again, and
# sent newer taps.
#
# Each request carries attendance_version: the version of this person's
# attendance on this meal that the page expects the server to have before
# this write. The meal form shows the version, and the page adds one for
# each of its own writes that has no answer yet. A request built on
# another version is refused with 409 and type "stale", and nothing is
# written.
RSpec.describe 'Attendance writes that reach the server out of order' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:alice) { create(:resident, community: community, unit: unit, name: 'Alice') }
  let(:token) { alice.keys.first.token }
  let(:meal) { create(:meal, community: community, date: community.today + 3) }
  let(:path) { "/api/v1/meals/#{meal.id}/residents/#{alice.id}" }

  # The version of Alice's attendance that the meal form shows.
  def form_version
    get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.parsed_body['residents'].find { |row| row['id'] == alice.id }['attendance_version']
  end

  # The version the page sends with a tap made while one of its own
  # writes, built on `version`, has no answer yet.
  def after_one_write(version)
    version && (version + 1)
  end

  def sign_up(version, late: false)
    post path, params: { token: token, late: late, vegetarian: false, attendance_version: version }, as: :json
  end

  def take_off(version)
    delete path, params: { token: token, attendance_version: version }, as: :json
  end

  def set_late(late, version)
    patch path, params: { token: token, late: late, attendance_version: version }, as: :json
  end

  def attending?
    meal.meal_residents.exists?(resident_id: alice.id)
  end

  it 'shows the version of each person\'s attendance on the meal form' do
    expect(form_version).to eq(0)

    sign_up(0)
    expect(response).to have_http_status(:ok)

    expect(form_version).to eq(1)
  end

  # Case C. The sign-up is held on the network. The page stops waiting,
  # loads the meal again (not signed up), and the person signs up and
  # then takes themselves off. Then the held sign-up arrives. It expects
  # "not signed up", and that is what the server has, so the state alone
  # cannot tell that it is old. Its version can.
  it 'refuses a sign-up that arrives after newer taps, and keeps the person off' do
    held = form_version

    sign_up(held)
    expect(response).to have_http_status(:ok)
    take_off(form_version)
    expect(response).to have_http_status(:ok)

    sign_up(held)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')
    expect(attending?).to be(false)
  end

  # Case A. Alice is signed up. She taps off and then on again at once.
  # The sign-up reaches the server first.
  it 'refuses a sign-up that arrives before the take-off it was tapped after' do
    sign_up(form_version)
    seen = form_version

    sign_up(after_one_write(seen))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')

    take_off(seen)
    expect(response).to have_http_status(:ok)
    expect(attending?).to be(false)
  end

  # The same for a take-off: Alice is off, taps on and then off. The
  # take-off reaches the server first.
  it 'refuses a take-off that arrives before the sign-up it was tapped after' do
    seen = form_version

    take_off(after_one_write(seen))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')

    sign_up(seen)
    expect(response).to have_http_status(:ok)
    expect(attending?).to be(true)
  end

  # Late on, then Late off. The second reaches the server first.
  it 'refuses a Late change that arrives before the one it was tapped after' do
    sign_up(form_version)
    seen = form_version

    set_late(false, after_one_write(seen))
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')

    set_late(true, seen)
    expect(response).to have_http_status(:ok)
    expect(meal.meal_residents.find_by(resident_id: alice.id).late).to be(true)
  end
end

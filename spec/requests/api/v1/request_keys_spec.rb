# frozen_string_literal: true

require 'rails_helper'

# A calendar write sent again with the same Idempotency-Key (challenge 30,
# ADR 0015). bin/faults found that a phone that sends a write, loses the
# answer and sends it again got an event saved twice, a "taken" 400 for
# its own guest room or common house booking, and a 404 for its own
# delete. With a key, the second send is answered with the first send's
# answer and writes nothing.
RSpec.describe 'Idempotency-Key on calendar writes' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:event_params) do
    { title: 'Work party', description: '', start_year: 2026, start_month: 5, start_day: 1,
      start_hours: 9, start_minutes: 0, end_hours: 12, end_minutes: 0 }
  end

  def send_twice(verb, path, params, key: '"one-key"', second_params: params)
    Array.new(2) do |time|
      public_send(verb, path, params: (time.zero? ? params : second_params).merge(token: token),
                              headers: { 'Idempotency-Key' => key })
      [response.status, response.parsed_body, response.headers['Idempotent-Replayed']]
    end
  end

  describe 'POST /api/v1/events' do
    it 'saves one event and answers the second send with the first answer, marked as replayed' do
      answers = send_twice(:post, '/api/v1/events', event_params)

      expect(answers).to eq([[200, { 'message' => 'Event has been created' }, nil],
                             [200, { 'message' => 'Event has been created' }, 'true']])
      expect(Event.count).to eq(1)
    end

    it 'refuses the same key with another request with 422, and saves nothing for it' do
      answers = send_twice(:post, '/api/v1/events', event_params, second_params: event_params.merge(title: 'Other'))

      expect(answers.map(&:first)).to eq([200, 422])
      expect(answers.last[1]['message']).to eq(RequestKey::OTHER_REQUEST)
      expect(Event.pluck(:title)).to eq(['Work party'])
    end

    it 'reads the request the same when only the push fields differ' do
      answers = send_twice(:post, '/api/v1/events', event_params.merge(socket_id: '1.1'),
                           second_params: event_params.merge(socket_id: '2.2'))

      expect(answers.map(&:first)).to eq([200, 200])
      expect(Event.count).to eq(1)
    end

    it 'refuses a key that is not a quoted string with 400, and saves nothing' do
      post '/api/v1/events', params: event_params.merge(token: token), headers: { 'Idempotency-Key' => 'no-quotes' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq(IdempotencyKeyHeader::INVALID)
      expect(Event.count).to eq(0)
    end

    it 'keeps the old behavior for a request with no key: each send saves an event' do
      2.times { post '/api/v1/events', params: event_params.merge(token: token) }

      expect(Event.count).to eq(2)
    end

    it 'looks up the key, not only the sender: a new key from the same sender saves a new event' do
      post '/api/v1/events', params: event_params.merge(token: token), headers: { 'Idempotency-Key' => '"first"' }
      post '/api/v1/events', params: event_params.merge(token: token), headers: { 'Idempotency-Key' => '"second"' }

      expect(response).to have_http_status(:ok)
      expect(response.headers['Idempotent-Replayed']).to be_nil
      expect(Event.count).to eq(2)
    end

    # The row holds the answer as JSON, as the server sent it, not a
    # string with JSON in it.
    it 'keeps the answer as JSON' do
      post '/api/v1/events', params: event_params.merge(token: token), headers: { 'Idempotency-Key' => '"k"' }

      expect(RequestKey.sole.body).to eq('message' => 'Event has been created')
    end

    it 'keeps a key per sender: another resident with the same key saves their own event' do
      other = create(:resident, community: community, unit: unit)
      post '/api/v1/events', params: event_params.merge(token: token), headers: { 'Idempotency-Key' => '"k"' }
      post '/api/v1/events', params: event_params.merge(token: other.keys.first.token),
                             headers: { 'Idempotency-Key' => '"k"' }

      expect(response.headers['Idempotent-Replayed']).to be_nil
      expect(Event.count).to eq(2)
    end

    it 'does not keep a refused write: the same key sent again after a fix is tried again' do
      bad = event_params.merge(title: '')
      post '/api/v1/events', params: bad.merge(token: token), headers: { 'Idempotency-Key' => '"k"' }
      expect(response).to have_http_status(:bad_request)
      expect(RequestKey.count).to eq(0)

      post '/api/v1/events', params: bad.merge(token: token), headers: { 'Idempotency-Key' => '"k"' }
      expect(response).to have_http_status(:bad_request)
      expect(response.headers['Idempotent-Replayed']).to be_nil
    end
  end

  describe 'PATCH /api/v1/events/:id/update' do
    it 'answers the second send with the first answer' do
      event = create(:event, community: community, title: 'Old')

      answers = send_twice(:patch, "/api/v1/events/#{event.id}/update", { title: 'New' })

      expect(answers.map { |status, _, replayed| [status, replayed] }).to eq([[200, nil], [200, 'true']])
      expect(event.reload.title).to eq('New')
    end
  end

  describe 'DELETE /api/v1/events/:id/delete' do
    it 'answers the second send with the first answer, not 404' do
      event = create(:event, community: community)

      answers = send_twice(:delete, "/api/v1/events/#{event.id}/delete", {})

      expect(answers).to eq([[200, { 'message' => 'Event has been removed' }, nil],
                             [200, { 'message' => 'Event has been removed' }, 'true']])
      expect(Event.count).to eq(0)
    end
  end

  describe 'POST /api/v1/guest-room-reservations/create' do
    it 'answers the second send with the first answer, not "taken"' do
      answers = send_twice(:post, '/api/v1/guest-room-reservations',
                           { resident_id: resident.id, date: '2026-04-15' })

      expect(answers.map { |status, _, replayed| [status, replayed] }).to eq([[200, nil], [200, 'true']])
      expect(GuestRoomReservation.count).to eq(1)
    end
  end

  describe 'DELETE /api/v1/guest-room-reservations/:id/delete' do
    it 'answers the second send with the first answer, not 404' do
      grr = create(:guest_room_reservation, community: community, resident: resident)

      answers = send_twice(:delete, "/api/v1/guest-room-reservations/#{grr.id}/delete", {})

      expect(answers.map(&:first)).to eq([200, 200])
      expect(GuestRoomReservation.count).to eq(0)
    end
  end

  describe 'POST /api/v1/common-house-reservations' do
    it 'answers the second send with the first answer, not "taken"' do
      answers = send_twice(:post, '/api/v1/common-house-reservations',
                           { resident_id: resident.id, title: 'Party', start_year: 2026, start_month: 5,
                             start_day: 1, start_hours: 14, start_minutes: 0, end_hours: 17, end_minutes: 0 })

      expect(answers.map { |status, _, replayed| [status, replayed] }).to eq([[200, nil], [200, 'true']])
      expect(CommonHouseReservation.count).to eq(1)
    end
  end

  # A guest remove has no attendance version (ADR 0012), so a page that
  # sends it again needs the key to be told it worked.
  describe 'DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id' do
    let(:meal) { create(:meal, community: community, date: community.today + 1) }
    let(:guest) { create(:guest, meal: meal, resident: resident) }
    let(:path) { "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}" }

    it 'answers the second send with the first answer, not 404' do
      answers = send_twice(:delete, path, {})

      expect(answers).to eq([[200, { 'message' => 'Guest was destroyed.' }, nil],
                             [200, { 'message' => 'Guest was destroyed.' }, 'true']])
      expect(meal.guests.count).to eq(0)
    end

    it 'leaves a bills save and a guest add to their own keys' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests",
           params: { token: token, vegetarian: false }, headers: { 'Idempotency-Key' => '"add-1"' }

      expect(response).to have_http_status(:ok)
      expect(RequestKey.count).to eq(0)
      expect(GuestAddKey.count).to eq(1)
    end
  end

  describe 'DELETE /api/v1/common-house-reservations/:id/delete' do
    it 'answers the second send with the first answer, not 404' do
      chr = create(:common_house_reservation, community: community, resident: resident)

      answers = send_twice(:delete, "/api/v1/common-house-reservations/#{chr.id}/delete", {})

      expect(answers.map(&:first)).to eq([200, 200])
      expect(CommonHouseReservation.count).to eq(0)
    end
  end
end

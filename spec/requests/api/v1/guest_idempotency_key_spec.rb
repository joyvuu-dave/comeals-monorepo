# frozen_string_literal: true

require 'rails_helper'

# The Idempotency-Key header on a guest add (S2, the same rules as a bills
# save: IETF draft "The Idempotency-Key HTTP Header Field", ADR 0009).
#
# A guest add whose answer is lost may or may not have been written. The
# meal page shows no guest then, so the person taps again. Without a key,
# the second tap adds a second guest when the first was written, and the
# host pays for two (tests/integration/meal-actions.spec.js shows it in a
# browser). With a key, the page sends the first tap's key again, and the
# server keeps the key of each guest add it wrote, in the same transaction
# as the guest, so a key it has seen adds nothing.
#
# The header's grammar is pinned in spec/services/idempotency_key_header_spec.rb.
# Two adds with the same key at the same moment are in
# spec/requests/api/v1/guest_idempotency_key_race_spec.rb.
RSpec.describe 'the Idempotency-Key header on POST /api/v1/meals/:meal_id/residents/:resident_id/guests' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.tomorrow) }
  let(:host) { create(:resident, community: community, unit: unit, name: 'Hana') }

  let(:replayed) { 'This guest was already added, so nothing more was added.' }

  def add_guest(key:, vegetarian: false, meal_id: meal.id, host_id: host.id, socket_id: nil)
    headers = key.nil? ? {} : { 'Idempotency-Key' => %("#{key}") }
    post "/api/v1/meals/#{meal_id}/residents/#{host_id}/guests",
         params: { vegetarian: vegetarian, token: token, socket_id: socket_id }.compact, headers: headers, as: :json
  end

  def guest_audits
    meal.associated_audits.where(auditable_type: 'Guest')
  end

  def guest_json(guest)
    { 'id' => guest.id, 'meal_id' => meal.id, 'resident_id' => host.id, 'vegetarian' => guest.vegetarian,
      'created_at' => guest.created_at.as_json }
  end

  describe 'a guest add without a key' do
    # A meal page loaded before guest adds took a key sends none, and
    # shows the answer's words to the person. A resident does not know
    # what a header is, so the words for them come first, and the
    # sentence for other API clients comes last.
    it 'is refused with 400 and adds no guest' do
      add_guest(key: nil)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq(
        'message' => 'This page is out of date. Nothing was saved. Reload the page and add the guest again. ' \
                     'A guest add needs an Idempotency-Key header, with a new key for each guest.'
      )
      expect(meal.guests.count).to eq(0)
    end
  end

  describe 'a key that is not a quoted string' do
    it 'is refused with 400 and adds no guest' do
      post "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests",
           params: { vegetarian: false, token: token }, headers: { 'Idempotency-Key' => 'not-quoted' }, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq(
        'message' => 'The Idempotency-Key header must be a quoted string of 1 to 255 characters, ' \
                     'like "8e03978e-40d5-43e8-bc93-6894a57f9324". Nothing was saved.'
      )
      expect(meal.guests.count).to eq(0)
    end
  end

  it 'keeps the key of the guest it added, with the host and the flag' do
    add_guest(key: 'first-tap', vegetarian: true)

    expect(response).to have_http_status(:ok)
    guest = meal.guests.sole
    expect(response.parsed_body).to eq(guest_json(guest))
    expect(GuestAddKey.sole).to have_attributes(meal_id: meal.id, key: 'first-tap', resident_id: host.id,
                                                vegetarian: true, guest_id: guest.id)
  end

  # Only an add whose key and flag are right is looked up. Any other add
  # is refused before the lock, so a look-up would be a read for nothing.
  it 'does not look up an add with no key, a wrong key, or a wrong flag' do
    statements = []
    record = ->(*, event) { statements << event[:sql] }

    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
      add_guest(key: nil)
      post "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests",
           params: { vegetarian: false, token: token }, headers: { 'Idempotency-Key' => 'not-quoted' }, as: :json
      add_guest(key: 'first-tap', vegetarian: 'maybe')
    end

    expect(statements.grep(/guest_add_keys/)).to eq([])
    expect(meal.guests.count).to eq(0)
  end

  describe 'a key the server has seen, for the same host and flag' do
    # The case the key is for: the first tap was written and its answer
    # was lost, and the person tapped again.
    it 'adds nothing, and answers with the guest the first tap added' do
      add_guest(key: 'first-tap')
      guest = meal.guests.sole
      audits = guest_audits.count

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => replayed, 'type' => 'replayed', 'guest' => guest_json(guest))
      expect(meal.guests.count).to eq(1)
      expect(guest_audits.count).to eq(audits)
    end

    # The page decides from this what the second tap meant: the guest it
    # added is gone, so the tap was for a new guest.
    it 'answers with no guest when the guest it added was removed since, and adds nothing' do
      add_guest(key: 'first-tap')
      meal.guests.sole.destroy!

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => replayed, 'type' => 'replayed', 'guest' => nil)
      expect(meal.guests.count).to eq(0)
      expect(GuestAddKey.sole.guest_id).to be_nil
    end

    # An admin can give a guest to another host on the meal form. Then the
    # guest the first tap added is no longer this host's guest, so the tap
    # was for a new guest, the same as when it was removed. An answer with
    # that guest would show it in the other host's row, and this host
    # would get no guest.
    it 'answers with no guest when the guest it added was given another host since, and adds nothing' do
      add_guest(key: 'first-tap')
      meal.guests.sole.update!(resident: resident)

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => replayed, 'type' => 'replayed', 'guest' => nil)
      expect(meal.guests.count).to eq(1)
    end

    it 'sends no live update' do
      add_guest(key: 'first-tap')
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      add_guest(key: 'first-tap')

      expect(response.parsed_body['type']).to eq('replayed')
      expect(Pusher).not_to have_received(:trigger)
    end

    # A resend can come with a new Pusher socket id (the connection
    # dropped, which is often why the answer was lost), with the flag in
    # another spelling, or form-encoded. All of these are the same add.
    it 'counts adds that ask for the same guest as the same add' do
      add_guest(key: 'first-tap', socket_id: '1.1')

      add_guest(key: 'first-tap', vegetarian: 0, socket_id: '2.2')
      expect(response.parsed_body['type']).to eq('replayed')

      post "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests",
           params: { vegetarian: 'false', token: token }, headers: { 'Idempotency-Key' => '"first-tap"' }
      expect(response.parsed_body['type']).to eq('replayed')
      expect(meal.guests.count).to eq(1)
    end

    # The key is looked up before the settled check. Its row was written
    # with the guest, while the meal was open, so the first tap was
    # written. The settled words would say it was not.
    describe 'after the meal was settled' do
      let(:meal) { create(:meal, community: community, date: Date.yesterday) }
      let(:settled_words) { 'Change not permitted. Meal has already been reconciled.' }

      before do
        add_guest(key: 'first-tap')
        meal.update!(reconciliation: create(:reconciliation, community: community))
      end

      it 'answers replayed, not with the settled words, and adds nothing' do
        add_guest(key: 'first-tap')

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('message' => replayed, 'type' => 'replayed')
        expect(response.parsed_body['guest']).to include('id' => meal.guests.sole.id)
      end

      it 'refuses the same key for another guest with 422, not with the settled words' do
        add_guest(key: 'first-tap', vegetarian: true)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['message']).to start_with('This Idempotency-Key was already used')
      end

      it 'answers a new key with the settled words' do
        add_guest(key: 'second-tap')

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => settled_words)
        expect(meal.guests.count).to eq(1)
      end

      # A key is looked up only for an add whose key and flag are right.
      # Any other add gets the settled words first, as every write does.
      it 'answers a seen key with the settled words when the flag is wrong' do
        add_guest(key: 'first-tap', vegetarian: 'maybe')

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => settled_words)
      end
    end

    # The same resend, when the first tap commits while the resend waits
    # for the meal lock, and a settlement takes the lock before the resend
    # does. Heroku's router answers 503 after 30 seconds while the first
    # tap is still running, so the page can send it again then. The
    # resend's look-up before the lock found no key, and its settled check
    # before the lock passed. So under the lock too, the key must be
    # looked up before the settled check. The wrapper puts the key's row
    # back and settles the meal inside that window.
    it 'answers replayed when the first tap and a settlement commit while the resend waits for the lock' do
      meal.update!(date: Date.yesterday)
      add_guest(key: 'first-tap')
      guest = meal.guests.sole
      GuestAddKey.find_by!(meal: meal, key: 'first-tap').delete
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)
      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          GuestAddKey.create!(meal_id: meal.id, key: 'first-tap', resident_id: host.id, vegetarian: false,
                              guest: guest)
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['type']).to eq('replayed')
      expect(meal.guests.count).to eq(1)
    end
  end

  describe 'a key the server has seen, for another guest' do
    let(:key_reused) do
      'This Idempotency-Key was already used for a different guest add. Nothing was saved. ' \
        'Send a new key with each guest add.'
    end

    it 'is refused with 422 when the flag differs, and adds nothing' do
      add_guest(key: 'first-tap', vegetarian: false)

      add_guest(key: 'first-tap', vegetarian: true)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('message' => key_reused)
      expect(meal.guests.count).to eq(1)
    end

    it 'is refused with 422 when the host differs, and adds nothing' do
      add_guest(key: 'first-tap')

      add_guest(key: 'first-tap', host_id: resident.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('message' => key_reused)
      expect(meal.guests.count).to eq(1)
    end

    # The host is compared the way the guest's resident_id is read, so
    # "010" is the same host as 10, and an id that is not one is another.
    it 'reads the host in the path the way the guest row reads it' do
      add_guest(key: 'first-tap')

      add_guest(key: 'first-tap', host_id: "0#{host.id}")
      expect(response.parsed_body['type']).to eq('replayed')

      add_guest(key: 'first-tap', host_id: 'none')
      expect(response).to have_http_status(:unprocessable_content)
      expect(meal.guests.count).to eq(1)
    end
  end

  # A key belongs to one meal. The unique index is on (meal_id, key).
  it 'adds a guest on another meal that comes with the same key' do
    other_meal = create(:meal, community: community, date: Date.tomorrow + 1)
    add_guest(key: 'same-key')

    add_guest(key: 'same-key', meal_id: other_meal.id)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key('type')
    expect(other_meal.guests.count).to eq(1)
  end

  # The server keeps only the key of a guest it added. An add it refused
  # wrote nothing, so the same key may come again, and is looked at fresh.
  describe 'a key whose add was refused' do
    it 'is not kept after the meal refused the guest, so the add is written once the meal takes it' do
      meal.update!(closed: true)
      add_guest(key: 'first-tap')
      expect(response.parsed_body).to eq('message' => 'Meal has been closed.')
      meal.update!(closed: false)

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key('type')
      expect(meal.guests.count).to eq(1)
    end

    # The key's row fails, once, after the guest was written; the
    # transaction takes back the guest and the key together.
    it 'is not kept when the add is rolled back, and takes its guest with it' do
      failed = false
      allow(GuestAddKey).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        unless failed
          failed = true
          raise ActiveRecord::RecordInvalid, GuestAddKey.new
        end

        original.call(*args, **kwargs)
      end
      add_guest(key: 'first-tap')
      expect(response).to have_http_status(:bad_request)
      expect(meal.guests.count).to eq(0)

      add_guest(key: 'first-tap')

      expect(response).to have_http_status(:ok)
      expect(meal.guests.count).to eq(1)
      expect(GuestAddKey.count).to eq(1)
    end
  end
end

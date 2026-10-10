# frozen_string_literal: true

require 'rails_helper'

# The Idempotency-Key header on a bills save (decision 6 of #135, IETF
# draft "The Idempotency-Key HTTP Header Field", ADR 0009). The page sends
# one new key with each save, and the same key when it sends that save
# again after no answer.
#
# The done rule alone makes a resend safe in every case but one: the first
# try was written and its answer was lost, and then someone set the bill
# back to the first try's `from`. The resend then matches `from` again and
# writes again, over that person's change, with no message. The key tells
# the two apart: the server keeps the key of each save it wrote, in the
# same transaction as the bills, and a key it has seen writes nothing.
#
# The header's grammar is pinned in spec/services/idempotency_key_header_spec.rb.
# Two saves with the same key at the same moment are in
# spec/requests/api/v1/bills_idempotency_key_race_spec.rb, and a retry
# after a SERIALIZABLE conflict in meal_write_retry_spec.rb.
RSpec.describe 'the Idempotency-Key header on PATCH /api/v1/meals/:meal_id/bills' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }
  let(:bob) { create(:resident, community: community, unit: unit, name: 'Bob') }
  let!(:bill) { create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('5')) }

  let(:replayed) { 'This save was already made, so nothing more was written.' }

  def save(edits, key:, meal_id: meal.id, socket_id: nil)
    headers = key.nil? ? {} : { 'Idempotency-Key' => %("#{key}") }
    patch "/api/v1/meals/#{meal_id}/bills", params: { edits: edits, token: token, socket_id: socket_id }.compact,
                                            headers: headers, as: :json
  end

  def change_bob(from, to)
    [{ op: 'change', resident_id: bob.id, from: { amount: from, no_cost: false }, to: { amount: to, no_cost: false } }]
  end

  def bill_audits
    meal.associated_audits.where(auditable_type: 'Bill')
  end

  describe 'a save without a key' do
    it 'is refused with 400 and writes nothing' do
      save(change_bob('5.0', '7.00'), key: nil)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq(
        'message' => 'A bills save needs an Idempotency-Key header, with a new key for each save. ' \
                     'Nothing was saved.'
      )
      expect(bill.reload.amount).to eq(BigDecimal('5'))
    end
  end

  describe 'a key that is not a quoted string' do
    it 'is refused with 400 and writes nothing' do
      patch "/api/v1/meals/#{meal.id}/bills", params: { edits: change_bob('5.0', '7.00'), token: token },
                                              headers: { 'Idempotency-Key' => 'not-quoted' }, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq(
        'message' => 'The Idempotency-Key header must be a quoted string of 1 to 255 characters, ' \
                     'like "8e03978e-40d5-43e8-bc93-6894a57f9324". Nothing was saved.'
      )
      expect(bill.reload.amount).to eq(BigDecimal('5'))
    end
  end

  # Only a save whose body and key are right is looked up. Any other save
  # is refused before the lock, so a look-up would be a read for nothing.
  it 'does not look up a save with no key, a wrong key, or wrong edits' do
    statements = []
    record = ->(*, event) { statements << event[:sql] }

    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
      save(change_bob('5.0', '7.00'), key: nil)
      patch "/api/v1/meals/#{meal.id}/bills", params: { edits: change_bob('5.0', '7.00'), token: token },
                                              headers: { 'Idempotency-Key' => 'not-quoted' }, as: :json
      save(change_bob('5.0', '7.001'), key: 'first-try')
    end

    expect(statements.grep(/bills_save_keys/)).to eq([])
    expect(bill.reload.amount).to eq(BigDecimal('5'))
  end

  # A page loaded before #135 sends no key. It must hear that it is out of
  # date, which tells the person what to do, not that a header is missing.
  it 'answers a save in the old format as out of date, with or without a key' do
    patch "/api/v1/meals/#{meal.id}/bills", params: { bills: [{ resident_id: bob.id }], token: token }, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['type']).to eq('outdated')
  end

  describe 'a key the server has seen with the same edits' do
    # The case the key is for. Without it, the resend in the last step
    # would match `from` again and write $7 over the other page's $5.
    it 'writes nothing, even when the bill was set back to the first try\'s from in between' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      expect(response).to have_http_status(:ok)
      save(change_bob('7.0', '5.00'), key: 'another-page')
      expect(bill.reload.amount).to eq(BigDecimal('5'))
      audits = bill_audits.count

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'message' => replayed, 'type' => 'replayed',
        'bills' => [{ 'resident_id' => bob.id, 'amount' => '5.0', 'no_cost' => false }]
      )
      expect(bill.reload.amount).to eq(BigDecimal('5'))
      expect(bill_audits.count).to eq(audits)
    end

    # The key is looked up before the stored bills are compared with the
    # edits. Here Bob's $9 is neither the first try's `from` nor its `to`,
    # so if the edits were compared first, the resend would get a stale
    # 409 that says nothing was saved. That would be false: the first try
    # was written.
    it 'answers replayed, not stale, when another page changed the bill to a third value in between' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      save(change_bob('7.0', '9.00'), key: 'another-page')
      expect(bill.reload.amount).to eq(BigDecimal('9'))

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        'message' => replayed, 'type' => 'replayed',
        'bills' => [{ 'resident_id' => bob.id, 'amount' => '9.0', 'no_cost' => false }]
      )
      expect(bill.reload.amount).to eq(BigDecimal('9'))
    end

    # The meal and its bills are read when the request starts. Another
    # page's save can commit after that and before the key is looked up,
    # and the answer must show the bills as stored when it is made.
    it 'answers with the bills as stored when it answers, not as the request first read them' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      allow(BillsSaveKey).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        Bill.where(id: bill.id).update_all(amount: BigDecimal('9'))
        original.call(*args, **kwargs)
      end

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response.parsed_body).to eq(
        'message' => replayed, 'type' => 'replayed',
        'bills' => [{ 'resident_id' => bob.id, 'amount' => '9.0', 'no_cost' => false }]
      )
    end

    it 'sends no live update' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response.parsed_body['type']).to eq('replayed')
      expect(Pusher).not_to have_received(:trigger)
    end

    # The key is checked against what the edits ask for, not against the
    # bytes sent. A resend can come with a new Pusher socket id (the
    # connection dropped, which is often why the answer was lost), in
    # another encoding, or with "7" for "7.00". All of these are the same
    # save.
    it 'counts edits that ask for the same bills as the same save' do
      save(change_bob('5.0', '7.00'), key: 'first-try', socket_id: '1.1')

      save(change_bob('5', '7'), key: 'first-try', socket_id: '2.2')
      expect(response.parsed_body['type']).to eq('replayed')

      patch "/api/v1/meals/#{meal.id}/bills", params: { edits: change_bob('5.00', '7.0'), token: token },
                                              headers: { 'Idempotency-Key' => '"first-try"' }
      expect(response.parsed_body['type']).to eq('replayed')
    end

    # The key is looked up before the settled check. Its row was written
    # with the first try's bills, while the meal was open, so the first
    # try was written. The settled words would say it was not: the meal
    # page shows them as "were not saved, because that meal has already
    # been settled".
    describe 'after the meal was settled' do
      let(:settled_words) { 'Change not permitted. Meal has already been reconciled.' }

      before do
        save(change_bob('5.0', '7.00'), key: 'first-try')
        meal.update!(reconciliation: create(:reconciliation, community: community))
      end

      it 'answers replayed, not with the settled words, and writes nothing' do
        audits = bill_audits.count

        save(change_bob('5.0', '7.00'), key: 'first-try')

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(
          'message' => replayed, 'type' => 'replayed',
          'bills' => [{ 'resident_id' => bob.id, 'amount' => '7.0', 'no_cost' => false }]
        )
        expect(bill.reload.amount).to eq(BigDecimal('7'))
        expect(bill_audits.count).to eq(audits)
      end

      it 'refuses other edits with the same key with 422, not with the settled words' do
        save(change_bob('7.0', '9.00'), key: 'first-try')

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['message']).to start_with('This Idempotency-Key was already used')
        expect(bill.reload.amount).to eq(BigDecimal('7'))
      end

      it 'answers a new key with the settled words' do
        save(change_bob('7.0', '9.00'), key: 'second-save')

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => settled_words)
      end

      # A key is looked up only for a save whose body and key are right.
      # Any other save gets the settled words first, as every write does.
      it 'answers a seen key with the settled words when the edits are wrong' do
        save(change_bob('5.0', '7.001'), key: 'first-try')

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq('message' => settled_words)
      end
    end

    # The same resend, when the first try commits while the resend waits
    # for the meal lock, and a settlement takes the lock before the
    # resend does. This can happen: Heroku's router answers 503 after 30
    # seconds while the first try is still running, and the page then
    # sends it again. The resend's look-up before the lock found no key,
    # and its settled check before the lock passed. So under the lock too,
    # the key must be looked up before the settled check. The wrapper puts
    # the key's row back and settles the meal inside that window.
    it 'answers replayed when the first try and a settlement commit while the resend waits for the lock' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      first_try = BillsSaveKey.find_by!(meal: meal, key: 'first-try')
      first_try.delete
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)
      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          BillsSaveKey.create!(meal_id: meal.id, key: 'first-try', edits_sha256: first_try.edits_sha256)
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['type']).to eq('replayed')
      expect(bill.reload.amount).to eq(BigDecimal('7'))
    end
  end

  describe 'a key the server has seen with other edits' do
    it 'is refused with 422 and writes nothing' do
      save(change_bob('5.0', '7.00'), key: 'first-try')
      audits = bill_audits.count

      save(change_bob('7.0', '9.00'), key: 'first-try')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq(
        'message' => 'This Idempotency-Key was already used for a different save. Nothing was saved. ' \
                     'Send a new key with each save.'
      )
      expect(bill.reload.amount).to eq(BigDecimal('7'))
      expect(bill_audits.count).to eq(audits)
    end
  end

  # A key belongs to one meal. The unique index is on (meal_id, key).
  it 'writes a save on another meal that comes with the same key' do
    other_meal = create(:meal, community: community, date: Date.yesterday - 1)
    other_bill = create(:bill, meal: other_meal, resident: bob, community: community, amount: BigDecimal('5'))
    save(change_bob('5.0', '7.00'), key: 'same-key')

    save(change_bob('5.0', '7.00'), key: 'same-key', meal_id: other_meal.id)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key('type')
    expect(other_bill.reload.amount).to eq(BigDecimal('7'))
  end

  # The server keeps only the key of a save it wrote. A save it refused
  # wrote nothing, so the same key may come again, and is looked at fresh.
  describe 'a key whose save was refused' do
    it 'is not kept after a stale 409' do
      save(change_bob('6.0', '7.00'), key: 'first-try')
      expect(response.parsed_body['type']).to eq('stale')
      bill.update!(amount: BigDecimal('6'))

      save(change_bob('6.0', '7.00'), key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key('type')
      expect(bill.reload.amount).to eq(BigDecimal('7'))
    end

    it 'is not kept after a 400 for the edits, so the fixed save is written' do
      save(change_bob('5.0', '7.001'), key: 'first-try')
      expect(response).to have_http_status(:bad_request)

      save(change_bob('5.0', '7.00'), key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('7'))
    end

    # The second cook's bill fails, once, after Bob's was written; the
    # transaction takes back Bob's bill and the key together.
    it 'is not kept when a write fails and the save is rolled back' do
      carol = create(:resident, community: community, unit: unit, name: 'Carol')
      edits = change_bob('5.0', '7.00') + [{ op: 'add', resident_id: carol.id, to: { amount: '1.00', no_cost: false } }]
      failed = false
      allow_any_instance_of(Bill).to receive(:save!).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance -- BillsPayload builds the record
        if original.receiver.resident_id == carol.id && !failed
          failed = true
          raise ActiveRecord::InvalidForeignKey, 'bills_resident_id_fkey'
        end

        original.call(*args, **kwargs)
      end
      save(edits, key: 'first-try')
      expect(response).to have_http_status(:bad_request)
      expect(bill.reload.amount).to eq(BigDecimal('5'))

      save(edits, key: 'first-try')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
      expect(meal.bills.reload.to_h { |b| [b.resident_id, b.amount] })
        .to eq(bob.id => BigDecimal('7'), carol.id => BigDecimal('1'))
    end
  end

  # The save was written, so its key is kept, and the answer is a 200.
  it 'keeps the key of a save that was written with the third-cook warning' do
    rotation = create(:rotation, community: community)
    future = create(:meal, community: community, date: 1.week.from_now, rotation: rotation)
    other = create(:meal, community: community, date: 2.weeks.from_now, rotation: rotation)
    cooks = Array.new(3) { create(:resident, community: community, unit: unit) }
    cooks.first(2).each { |cook| create(:bill, meal: future, resident: cook, community: community) }
    create(:bill, meal: other, resident: cooks.first, community: community)
    add_third = [{ op: 'add', resident_id: cooks.last.id, to: { amount: '0', no_cost: false } }]
    save(add_third, key: 'first-try', meal_id: future.id)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['type']).to eq('warning')

    save(add_third, key: 'first-try', meal_id: future.id)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['type']).to eq('replayed')
    expect(future.bills.count).to eq(3)
  end
end

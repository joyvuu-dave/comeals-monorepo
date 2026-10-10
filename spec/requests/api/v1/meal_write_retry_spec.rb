# frozen_string_literal: true

require 'rails_helper'

# A meal write refused once for a conflict and then retried (RetryOnConflict,
# ADR 0005). The first attempt assigned the new values to the meal and then
# failed in the database; Rails rolls the row back but leaves the tried
# values on the in-memory record, and `with_lock` (`lock!`) refuses to lock
# a record with unsaved changes. So the retry raised RuntimeError — a 500
# for a write that would have gone through on the second try. Found by
# spec/concurrency/request_storm_spec.rb (2026-09-11).
#
# Without a test transaction, because RetryOnConflict does not retry inside
# one (it cannot: a refused transaction is done for).
# prosopite is off here: a retry runs the meal lookup again on purpose,
# and that is not an N+1.
RSpec.describe 'a meal write retried after a conflict', prosopite: false do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let!(:meal) { create(:meal, community: community) }

  # The database refuses the first save after the values are assigned,
  # the way a serialization failure on the UPDATE arrives.
  def refuse_first_save
    refused = false
    allow_any_instance_of(Meal).to receive(:save!).and_wrap_original do |save, *args| # rubocop:disable RSpec/AnyInstance -- the controller loads the record
      if refused
        save.call(*args)
      else
        refused = true
        raise ActiveRecord::SerializationFailure, 'could not serialize access due to concurrent update'
      end
    end
  end

  it 'closes the meal on the second try' do
    refuse_first_save

    patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: true }

    expect(response).to have_http_status(:ok)
    expect(meal.reload).to be_closed
  end

  it 'updates the description on the second try' do
    refuse_first_save

    patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Second try' }

    expect(response).to have_http_status(:ok)
    expect(meal.reload.description).to eq('Second try')
  end

  it 'sets the cap on the second try' do
    meal.update!(closed: true)
    refuse_first_save

    patch "/api/v1/meals/#{meal.id}/max", params: { token: token, max: 5 }

    expect(response).to have_http_status(:ok)
    expect(meal.reload.max).to eq(5)
  end

  # A bills save reads the stored bills again on each try. Here the first
  # try writes Bob's $7 and is refused, and another page's $9 for Bob
  # commits while this one waits to try again. The second try finds $9,
  # not the $5 this page saw, so it must answer stale and keep the $9.
  # A save that read the bills once, before the first try, would write
  # $7 over the other page's $9 with no message.
  it 'answers a bills save stale when another save committed between two tries' do
    cook = create(:resident, community: community, unit: unit, name: 'Bob')
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('5'))
    token
    refuse_first_bill_update
    allow(RetryOnConflict).to receive(:sleep) { Bill.where(id: bill.id).update_all(amount: BigDecimal('9')) }

    patch "/api/v1/meals/#{meal.id}/bills", params: {
      token: token, edits: [{ op: 'change', resident_id: cook.id, from: { amount: '5.0', no_cost: false },
                              to: { amount: '7.00', no_cost: false } }]
    }, headers: BillEdits.key_header, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['type']).to eq('stale')
    expect(bill.reload.amount).to eq(BigDecimal('9'))
  end

  # The save's Idempotency-Key is written in the same transaction as its
  # bills (decision 6 of #135). Here the first try writes Bob's $7 and its
  # key, and is then refused. The rollback must take the key too: a key
  # left behind would make the second try answer "already made" for a save
  # that was never written.
  it 'writes a bills save on the second try, and keeps its key once, when the first try wrote its key' do
    cook = create(:resident, community: community, unit: unit, name: 'Bob')
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('5'))
    token
    allow(RetryOnConflict).to receive(:sleep)
    refused = false
    allow(BillsSaveKey).to receive(:create!).and_wrap_original do |create, *args, **kwargs|
      create.call(*args, **kwargs).tap do
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
        end
      end
    end

    patch "/api/v1/meals/#{meal.id}/bills", params: {
      token: token, edits: [{ op: 'change', resident_id: cook.id, from: { amount: '5.0', no_cost: false },
                              to: { amount: '7.00', no_cost: false } }]
    }, headers: BillEdits.key_header('the-key'), as: :json

    expect(refused).to be(true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key('type')
    expect(bill.reload.amount).to eq(BigDecimal('7'))
    expect(meal.associated_audits.where(auditable_type: 'Bill', action: 'update').count).to eq(1)
    expect(BillsSaveKey.where(meal_id: meal.id).pluck(:key)).to eq(['the-key'])
  end

  # The same for a guest add's Idempotency-Key (S2): the first try writes
  # the guest and its key's row, and is then refused. The rollback must
  # take both. A key left behind would make the second try answer
  # "replayed" with no guest, and a guest left behind would be added twice.
  it 'adds a guest on the second try, and keeps its key once, when the first try wrote its key' do
    host = create(:resident, community: community, unit: unit, name: 'Hana')
    token
    allow(RetryOnConflict).to receive(:sleep)
    refused = false
    allow(GuestAddKey).to receive(:create!).and_wrap_original do |create, *args, **kwargs|
      create.call(*args, **kwargs).tap do
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
        end
      end
    end

    post "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests",
         params: { token: token, vegetarian: false }, headers: { 'Idempotency-Key' => '"the-key"' }, as: :json

    expect(refused).to be(true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key('type')
    expect(meal.guests.count).to eq(1)
    expect(meal.associated_audits.where(auditable_type: 'Guest', action: 'create').count).to eq(1)
    expect(GuestAddKey.where(meal_id: meal.id).pluck(:key)).to eq(['the-key'])
  end

  def refuse_first_bill_update
    refused = false
    allow_any_instance_of(Bill).to receive(:update!).and_wrap_original do |update, *args, **kwargs| # rubocop:disable RSpec/AnyInstance -- the save loads the record
      update.call(*args, **kwargs)
      next if refused

      refused = true
      raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
    end
  end

  # Every try is refused after it wrote: the conflict arrives after the
  # INSERT, inside the lock's transaction, as a SERIALIZABLE refusal often
  # does. The transaction rolls the row back each time, so the 409's
  # "Nothing was saved" is true, and a rolled-back write pushes nothing
  # (LiveUpdate drops the notes of a transaction that rolls back).
  it 'answers 409, with no row and no push, when every try is refused after it wrote' do
    token
    allow(RetryOnConflict).to receive(:sleep)
    allow_any_instance_of(MealResident).to receive(:update!).and_wrap_original do |update, *args, **kwargs| # rubocop:disable RSpec/AnyInstance -- the controller builds the record
      update.call(*args, **kwargs)
      raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
    end
    # The rows above committed and pushed; only the request's pushes count.
    RSpec::Mocks.space.proxy_for(Pusher).reset
    allow(Pusher).to receive(:trigger)

    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: false, vegetarian: false }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['message']).to eq(
      'Someone else was changing this meal at the same time. Nothing was saved. Try again.'
    )
    expect(MealResident.where(meal_id: meal.id, resident_id: resident.id)).not_to exist
    expect(Pusher).not_to have_received(:trigger)
  end
end

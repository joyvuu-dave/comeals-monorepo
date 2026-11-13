# frozen_string_literal: true

require 'rails_helper'

# A settled meal refuses every change. A close, a cancel, a description or
# a cap that sends the value the meal already has is no change, so it gets
# the answer the send that saved it got (#280). bin/faults found the case:
# a cook closes a dinner, the phone does not get the answer, a settlement
# settles the dinner, and the phone sends the close again. Before, it was
# told "already been reconciled" for a close that was saved.
RSpec.describe 'A settled meal sent the value it already has' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:settled_words) { 'Change not permitted. Meal has already been reconciled.' }
  let(:meal) { create(:meal, community: community, description: 'Soup') }

  def settle!
    meal.update_columns(reconciliation_id: create(:reconciliation, community: community, end_date: meal.date - 30).id)
  end

  def send_patch(field, value)
    patch "/api/v1/meals/#{meal.id}/#{field}", params: { token: token, field => value }
  end

  def answer = [response.status, response.parsed_body['message']]

  it 'answers a close sent again after the meal was settled as the first close was answered' do
    send_patch(:closed, true)
    first = answer
    expect(meal.reload.closed).to be(true)
    settle!

    send_patch(:closed, true)

    expect(first).to eq([200, 'Meal closed value updated.'])
    expect(answer).to eq(first)
  end

  # The rule is only for a settled meal. On any other meal the write runs
  # as before, and the save tells the meal page (Meal#note_live_update).
  it 'saves a close sent again to a meal that is not settled, and tells the meal page' do
    meal.update!(closed: true)
    token
    # Forget the pushes the setup sent, so the only one counted is the
    # request's.
    RSpec::Mocks.space.proxy_for(Pusher).reset
    allow(Pusher).to receive(:trigger)

    send_patch(:closed, true)

    expect(answer).to eq([200, 'Meal closed value updated.'])
    expect(Pusher).to have_received(:trigger).with("meal-#{meal.id}", 'update', anything, any_args).at_least(:once)
  end

  it 'refuses a close of a settled meal that is open' do
    settle!

    send_patch(:closed, true)

    expect(answer).to eq([400, settled_words])
    expect(meal.reload.closed).to be(false)
  end

  it 'gives the settled words to a value it cannot read, before it reads it' do
    meal.update!(closed: true, max: 5)
    settle!

    send_patch(:closed, 'maybe')
    expect(answer).to eq([400, settled_words])

    send_patch(:cancelled, 'maybe')
    expect(answer).to eq([400, settled_words])

    send_patch(:max, 'five')
    expect(answer).to eq([400, settled_words])
  end

  it 'gives the settled words to a description or a cap left out of the request' do
    meal.update!(closed: true)
    settle!

    patch "/api/v1/meals/#{meal.id}/description", params: { token: token }
    expect(answer).to eq([400, settled_words])

    patch "/api/v1/meals/#{meal.id}/max", params: { token: token }
    expect(answer).to eq([400, settled_words])
  end

  it 'gives the settled words to an unreadable cap on a meal with no cap' do
    meal.update!(closed: true)
    settle!

    send_patch(:max, 'five')

    expect(answer).to eq([400, settled_words])
  end

  # The rule is only for these four writes. Every other write on a
  # settled meal is refused before anything else is looked up.
  it 'refuses every other write on a settled meal first' do
    settle!

    delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/0", params: { token: token }

    expect(answer).to eq([400, settled_words])
  end

  it 'still refuses a reopen of a settled meal' do
    meal.update!(closed: true)
    settle!

    send_patch(:closed, false)

    expect(answer).to eq([400, settled_words])
    expect(meal.reload.closed).to be(true)
  end

  it 'answers the description it already has, and refuses another' do
    settle!

    send_patch(:description, 'Soup')
    expect(answer).to eq([200, 'Description updated.'])

    send_patch(:description, 'Stew')
    expect(answer).to eq([400, settled_words])
    expect(meal.reload.description).to eq('Soup')
  end

  it 'answers the cap it already has, and refuses another or none' do
    meal.update!(closed: true, max: 5)
    settle!

    send_patch(:max, '5')
    expect(answer).to eq([200, 'Meal max value updated.'])

    send_patch(:max, '6')
    expect(answer).to eq([400, settled_words])

    send_patch(:max, nil)
    expect(answer).to eq([400, settled_words])
    expect(meal.reload.max).to eq(5)
  end

  it 'answers no cap when it has none, and refuses a cap' do
    meal.update!(closed: true)
    settle!

    send_patch(:max, nil)
    expect(answer).to eq([200, 'Meal max value updated.'])

    send_patch(:max, '5')
    expect(answer).to eq([400, settled_words])
  end

  it 'answers a restore of a settled dinner that is not cancelled, and refuses a cancel' do
    settle!

    send_patch(:cancelled, false)
    expect(answer).to eq([200, 'Dinner restored.'])

    send_patch(:cancelled, true)
    expect(answer).to eq([400, settled_words])
    expect(meal.reload.cancelled_at).to be_nil
  end

  it 'answers a cancel of a settled dinner that is cancelled, and refuses a restore' do
    meal.cancel!
    settle!

    send_patch(:cancelled, true)
    expect(answer).to eq([200, 'Dinner cancelled.'])

    send_patch(:cancelled, false)
    expect(answer).to eq([400, settled_words])
    expect(meal.reload.cancelled_at).not_to be_nil
  end

  # The check before the lock reads the meal as the request found it. A
  # settlement can commit between that read and the lock, so the check
  # under the lock decides too.
  describe 'when the meal is settled while the request waits for the lock' do
    before do
      meal.update!(closed: true)
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)
      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the settlement commits inside one request
        .and_wrap_original do |original, *args, &block|
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end
    end

    it 'answers the value the meal has as saved' do
      send_patch(:closed, true)

      expect(answer).to eq([200, 'Meal closed value updated.'])
    end

    it 'refuses a change' do
      send_patch(:closed, false)

      expect(answer).to eq([400, settled_words])
      expect(meal.reload.closed).to be(true)
    end
  end
end

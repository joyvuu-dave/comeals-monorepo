# frozen_string_literal: true

require 'rails_helper'

# A read refused for a conflict.
#
# At SERIALIZABLE PostgreSQL may refuse any transaction, including one
# that only reads — and the calendar month reads nine tables and then
# writes a cache entry, which makes it a likely pick when a meal write
# commits underneath it. Nothing rescued that, so the answer was a 500 on
# a page that changes nothing. The request storm hits it about one run in
# three (docs/concurrency-testing.md).
#
# Two answers, in order: the month is rebuilt (a read is always safe to
# run again), and a refusal that will not go away is a 409 like every
# other conflict, never a 500.
RSpec.describe 'a read refused for a conflict' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  before { allow(RetryOnConflict).to receive(:sleep) }

  it 'builds the calendar month on the second try' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))
    refused = false
    allow_any_instance_of(Community).to receive(:calendar_cache_version).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance -- the controller loads the record
      raise ActiveRecord::SerializationFailure, 'could not serialize access' unless refused

      original.call(*args)
    ensure
      refused = true
    end

    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['meals'].size).to eq(1)
  end

  it 'answers 409, not 500, when the refusal does not go away, and reports it with the action' do
    allow_any_instance_of(Community).to receive(:calendar_cache_version) # rubocop:disable RSpec/AnyInstance -- the refusal happens inside one request
      .and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')
    allow(Rails.error).to receive(:report).and_call_original

    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['message']).to eq(
      'Someone else was changing this at the same time. Nothing was saved. Try again.'
    )
    expect(Rails.error).to have_received(:report).with(
      an_instance_of(ActiveRecord::SerializationFailure),
      handled: true, severity: :warning, context: { controller: 'communities', action: 'calendar' }
    )
  end

  # A write action's own rescue is inside with_meal_lock, so a refusal in
  # a before_action (here the resident lookup) escapes it. Nothing has
  # been written at that point, so "Nothing was saved" is true, and the
  # answer is the same 409. (A refusal during the render, after the lock
  # has committed the row, is not tested here: the row is saved by then,
  # and the serializers these actions render run no query.)
  it 'answers 409 when a write action is refused before it writes' do
    meal = create(:meal, community: community)
    allow(Resident).to receive(:exists?).and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')
    allow(Rails.error).to receive(:report).and_call_original

    expect do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
           params: { token: token, late: false, vegetarian: false }
    end.not_to change(MealResident, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['message']).to eq(
      'Someone else was changing this at the same time. Nothing was saved. Try again.'
    )
    expect(Rails.error).to have_received(:report).with(
      an_instance_of(ActiveRecord::SerializationFailure),
      handled: true, severity: :warning, context: { controller: 'meals', action: 'create_meal_resident' }
    )
  end
end

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
RSpec.describe 'a meal write retried after a conflict' do
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
end

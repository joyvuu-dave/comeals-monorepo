# frozen_string_literal: true

require 'rails_helper'

# ADR 0005: "A refused transaction has written nothing, so 409 is the true
# answer." ADR 0007 and LiveUpdate: after the commit, the flush clears the
# calendar cache and enqueues the pushes; a failure there "is reported, not
# raised: the write has committed, and raising here would answer 500 for a
# change that is in the database."
#
# LiveUpdate#push keeps that promise. LiveUpdate#flush's cache clear does
# not: `Rails.cache.delete` is a DELETE on solid_cache_entries, in the same
# SERIALIZABLE session as everything else, and solid_cache's failsafe
# swallows lock and timeout errors but not ActiveRecord::SerializationFailure
# (SolidCache::Store::Failsafe::TRANSIENT_ACTIVE_RECORD_ERRORS). So a
# refused clear raises out of the after-commit callback, into
# RetryOnConflict, which was written for a write that was rolled back: it
# runs the block again. The guest is already in the database, so the
# retry writes a second one. When the refusal keeps happening the person
# sees a 409 that says "Nothing was saved" over three committed guests.
#
# The refusal is simulated with a stub, because making PostgreSQL abort
# exactly that one DELETE on purpose needs three transactions in a cycle.
# The error class is the one a SERIALIZABLE session gets.
#
# Invariant hunt, 2026-09-21. Red when written: a finding.
RSpec.describe 'a refused cache clear after the commit' do
  # No test transaction: RetryOnConflict does not retry while a transaction
  # is open, and in production none is. With the test transaction the
  # request answers 409 and writes one guest; without it, what production
  # does.
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }
  let(:token) { resident.keys.first.token }

  def refusal
    ActiveRecord::SerializationFailure.new(
      'PG::TRSerializationFailure: ERROR:  could not serialize access due to read/write dependencies ' \
      'among transactions'
    )
  end

  def post_guest
    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: { token: token, vegetarian: false }
  end

  before do
    token
    meal
    allow(Rails.error).to receive(:report).and_call_original
  end

  it 'writes the guest once and answers success when the clear is refused once' do
    calls = 0
    allow(Rails.cache).to receive(:delete).and_wrap_original do |original, *args|
      calls += 1
      raise refusal if calls == 1

      original.call(*args)
    end

    expect { post_guest }.to change(Guest, :count).by(1)
    expect(response).to have_http_status(:ok)
  end

  it 'writes the guest once, answers success and reports the failure when the clear stays refused' do
    allow(Rails.cache).to receive(:delete).and_raise(refusal)

    expect { post_guest }.to change(Guest, :count).by(1)
    expect(response).to have_http_status(:ok)
    # Once per refused clear: a write touches every month the change can
    # show on, and each clear reports on its own and goes on.
    expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::SerializationFailure),
                                                       hash_including(handled: true)).at_least(:once)
  end
end

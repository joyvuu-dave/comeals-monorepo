# frozen_string_literal: true

require 'rails_helper'

# The calendar month is cached per month. A write clears the entry and
# then pushes, so a client that refetches gets fresh data. But a request
# that was already building the month when the write committed has read
# the old rows, and it stores what it read AFTER the write cleared the
# entry. The stale copy then serves everyone for up to an hour, and the
# push cannot fix it — the refetch it causes reads the stale copy.
#
# Deleting the entry cannot close this window. What closes it is a
# version read before the rows: an entry stored under an old version is
# a miss for every later reader (Rails.cache.fetch's `version:`).
RSpec.describe 'the calendar cache after a write that lands mid-build' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  # The test environment uses a null cache store, which would hide the bug.
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  it 'does not keep serving the month as it was before the write' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))
    landed = false

    # The first request reads the rows, and then — while it is still
    # inside the cache fetch, before it stores — an event is created.
    allow(CalendarSerializer).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      serializer = original.call(*args, **kwargs)
      allow(serializer).to receive(:to_h).and_wrap_original do |to_h|
        data = to_h.call
        unless landed
          landed = true
          create(:event, community: community, title: 'Landed mid-build',
                         start_date: Time.zone.local(2026, 4, 12, 18), end_date: Time.zone.local(2026, 4, 12, 20))
        end
        data
      end
      serializer
    end

    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    expect(response).to have_http_status(:ok)
    # This request read the rows before the event existed, so it is right
    # not to show it.
    expect(response.body).not_to include('Landed mid-build')

    # The next request is after the write. The push told every client to
    # refetch, and this is that refetch.
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Landed mid-build')
  end
end

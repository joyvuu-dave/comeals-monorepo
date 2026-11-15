# frozen_string_literal: true

require 'rails_helper'

# Production counts throttle hits in the throttle_counts table, through
# ThrottleStore (#292). Every other rack_attack spec runs against a
# MemoryStore, which proves the throttle config but says nothing about the
# store that holds the counts in production.
#
# Counting is the one thing that differs from plain read/write. Rack::Attack
# calls store.increment on a key that may not exist yet, and takes a nil
# answer to mean "no count yet", writing 1 over whatever is there. This spec
# pins the behaviour end to end: real requests, a real ThrottleStore, real
# Postgres rows. Two requests at the same moment are in
# spec/concurrency/shared_address_spec.rb.
#
# The test environment counts nothing (spec/support/rack_attack.rb), so
# pointing Rack::Attack at the real store here is not optional: against the
# null store every count would read back as nothing and the throttle would
# never trip, passing vacuously.
RSpec.describe 'Rack::Attack throttles backed by ThrottleStore' do
  include ActiveSupport::Testing::TimeHelpers

  # Rack::Attack keys each counter by the clock's period (5 minutes for
  # login, an hour for password resets, a minute for the API). A run that
  # crossed a period's edge would start the count again and miss the
  # throttle. So the clock is held one second after an hour starts, which
  # is the start of a period for every throttle here.
  before { travel_to(Time.utc(2026, 4, 1, 12, 0, 1)) }

  # The rows are in the example's transaction, so each example starts with
  # an empty table.
  around do |example|
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = ThrottleStore.new
    example.run
    Rack::Attack.cache.store = original
  end

  it 'stores its counters in throttle_counts, not in the cache' do
    expect do
      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.1.0.1' }
    end.not_to change(SolidCache::Entry, :count)

    expect(ThrottleCount.pluck(:key, :count))
      .to contain_exactly(['rack::attack:5916816:login/ip:10.1.0.1', 1], ['rack::attack:29584080:api/ip:10.1.0.1', 1])
  end

  it 'counts up across requests instead of resetting each time' do
    3.times do
      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.1.0.2' }
    end

    # Rack::Attack hangs the running count off the request env for every
    # throttle it evaluated.
    throttle_data = request.env['rack.attack.throttle_data']['login/ip']

    expect(throttle_data[:count]).to eq(3)
  end

  it 'trips the login throttle on the 21st attempt from one IP' do
    20.times do
      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.1.0.3' }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post '/api/v1/residents/token',
         params: { email: 'nobody@example.com', password: 'wrong' },
         env: { 'REMOTE_ADDR' => '10.1.0.3' }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body['message']).to include('Too many requests')
    expect(response.headers['Retry-After']).to be_present
  end

  it 'keeps counters separate per IP' do
    21.times do
      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.1.0.4' }
    end
    expect(response).to have_http_status(:too_many_requests)

    post '/api/v1/residents/token',
         params: { email: 'nobody@example.com', password: 'wrong' },
         env: { 'REMOTE_ADDR' => '10.1.0.5' }

    expect(response).not_to have_http_status(:too_many_requests)
  end

  it 'trips the password-reset throttle on the 11th request' do
    10.times do
      post '/api/v1/residents/password-reset',
           params: { email: 'nobody@example.com' },
           env: { 'REMOTE_ADDR' => '10.1.0.6' }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post '/api/v1/residents/password-reset',
         params: { email: 'nobody@example.com' },
         env: { 'REMOTE_ADDR' => '10.1.0.6' }

    expect(response).to have_http_status(:too_many_requests)
  end

  describe 'increment on a key that does not exist yet' do
    # The exact edge Rack::Attack works around. Whatever increment returns for
    # a missing key, the count that comes back must be 1, never 0 or nil.
    it 'starts the count at 1' do
      count = Rack::Attack.cache.count('some/fresh/key', 1.minute)

      expect(count).to eq(1)
    end

    it 'goes 1, 2, 3 on repeat counts' do
      counts = Array.new(3) { Rack::Attack.cache.count('another/fresh/key', 1.minute) }

      expect(counts).to eq([1, 2, 3])
    end
  end

  describe 'Rack::Attack.reset!' do
    # Rack::Attack.reset! clears every counter by calling
    # store.delete_matched with a Ruby pattern, and ThrottleStore has no
    # such call. reset! is a test and console helper; nothing on the request
    # path calls it. To clear the counts by hand, empty the table:
    # ThrottleCount.delete_all.
    it 'is not available when counters live in throttle_counts' do
      expect { Rack::Attack.reset! }.to raise_error(Rack::Attack::IncompatibleStoreError, /delete_matched/)
    end
  end
end

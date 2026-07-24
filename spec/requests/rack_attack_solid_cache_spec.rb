# frozen_string_literal: true

require 'rails_helper'

# Production counts throttle hits in solid_cache. Every other rack_attack spec
# runs against a MemoryStore, which proves the throttle config but says nothing
# about the store that actually holds the counters in production.
#
# Counting is the one thing that differs from plain read/write. Rack::Attack
# calls store.increment on a key that may not exist yet, and stores disagree
# about that case — memcached returns nil, and Rack::Attack falls back to
# writing 1. This spec pins the behaviour end to end: real HTTP requests, real
# SolidCache::Store, real Postgres rows.
#
# The test environment caches to :null_store, so pointing Rack::Attack at a
# real store here is not optional — against null_store every count would read
# back as nothing and the throttle would never trip, passing vacuously.
RSpec.describe 'Rack::Attack throttles backed by SolidCache' do
  # A fresh namespace per example is how these specs isolate from each other.
  # The obvious alternative, Rack::Attack.reset!, does not work here — see the
  # delete_matched example at the bottom of this file.
  let(:solid_cache) { SolidCache::Store.new(namespace: "rack-attack-spec-#{SecureRandom.hex(4)}") }

  around do |example|
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = solid_cache
    example.run
    Rack::Attack.cache.store = original
  end

  it 'stores its counters in solid_cache, not somewhere else' do
    post '/api/v1/residents/token',
         params: { email: 'nobody@example.com', password: 'wrong' },
         env: { 'REMOTE_ADDR' => '10.1.0.1' }

    expect(SolidCache::Entry.count).to be_positive
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
    # A real difference from memcached, pinned here so it is not a surprise
    # later. Rack::Attack.reset! clears every counter by calling
    # store.delete_matched, and solid_cache does not implement that — matching
    # keys by pattern is not something the entries table supports.
    #
    # This costs production nothing: reset! is a test and console helper.
    # Nothing on the request path calls it, and nothing in app/, config/, or
    # lib/ calls delete_matched at all. To clear throttle counters by hand in
    # production, use Rails.cache.clear (what bin/deploy already runs) or
    # delete the specific key.
    it 'is not available when counters live in solid_cache' do
      expect { Rack::Attack.reset! }.to raise_error(NotImplementedError, /delete_matched/)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Rack::Attack throttles' do
  # Test env caches to :null_store (nothing persists), so throttle counters
  # never accumulate. Swap in a real in-memory cache for these specs only.
  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = memory_cache
    Rack::Attack.reset!
    example.run
    Rack::Attack.cache.store = original
  end

  # Simulate a specific client IP. Use 10.x addresses so we're not fighting
  # any other throttle bucket across examples.
  def from_ip(_ip, &)
    yield

    # no-op; IP set via env in each request below
  end

  describe 'registered throttles' do
    it 'configures login, password-reset, and blanket-api throttles' do
      expect(Rack::Attack.throttles.keys).to include(
        'login/ip', 'password-reset/ip', 'api/ip'
      )
    end

    it 'uses conservative thresholds' do
      expect(Rack::Attack.throttles['login/ip'].limit).to eq(20)
      expect(Rack::Attack.throttles['login/ip'].period).to eq(5.minutes)

      expect(Rack::Attack.throttles['password-reset/ip'].limit).to eq(10)
      expect(Rack::Attack.throttles['password-reset/ip'].period).to eq(1.hour)

      expect(Rack::Attack.throttles['api/ip'].limit).to eq(600)
      expect(Rack::Attack.throttles['api/ip'].period).to eq(1.minute)
    end
  end

  describe 'POST /api/v1/residents/token (login)' do
    it 'lets the first 20 attempts through and throttles the 21st' do
      20.times do
        post '/api/v1/residents/token',
             params: { email: 'nobody@example.com', password: 'wrong' },
             env: { 'REMOTE_ADDR' => '10.0.0.1' }
        expect(response).not_to have_http_status(:too_many_requests)
      end

      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.0.0.1' }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body['message']).to include('Too many requests')
      expect(response.headers['Retry-After']).to be_present
    end

    it 'throttles per IP — a different IP is unaffected' do
      21.times do
        post '/api/v1/residents/token',
             params: { email: 'nobody@example.com', password: 'wrong' },
             env: { 'REMOTE_ADDR' => '10.0.0.1' }
      end
      expect(response).to have_http_status(:too_many_requests)

      post '/api/v1/residents/token',
           params: { email: 'nobody@example.com', password: 'wrong' },
           env: { 'REMOTE_ADDR' => '10.0.0.2' }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe 'POST /api/v1/residents/password-reset' do
    it 'throttles after 10 requests from the same IP' do
      10.times do
        post '/api/v1/residents/password-reset',
             params: { email: 'nobody@example.com' },
             env: { 'REMOTE_ADDR' => '10.0.0.3' }
      end

      post '/api/v1/residents/password-reset',
           params: { email: 'nobody@example.com' },
           env: { 'REMOTE_ADDR' => '10.0.0.3' }

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end

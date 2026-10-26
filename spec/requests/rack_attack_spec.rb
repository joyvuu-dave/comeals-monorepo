# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Rack::Attack throttles' do
  include ActiveSupport::Testing::TimeHelpers

  # Rack::Attack keys each counter by the clock's period (5 minutes for
  # login, an hour for password resets, a minute for the API). A run that
  # crossed a period's edge would start the count again and miss the
  # throttle. So the clock is held one second after an hour starts, which
  # is the start of a period for every throttle here.
  before { travel_to(Time.utc(2026, 4, 1, 12, 0, 1)) }

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

      expect(Rack::Attack.throttles['browser-reports/ip'].limit).to eq(60)
      expect(Rack::Attack.throttles['browser-reports/ip'].period).to eq(10.minutes)

      expect(Rack::Attack.throttles['browser-report-alerts/ip'].limit).to eq(10)
      expect(Rack::Attack.throttles['browser-report-alerts/ip'].period).to eq(1.hour)
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

  # The browser check sends one report per page load, with no login. A
  # failed or broken check alerts the owner, so those have a much
  # smaller limit: a script cannot fill the owner's inbox from one
  # address.
  describe 'POST /api/v1/browser-reports' do
    let(:iphone) do
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 ' \
        '(KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1'
    end

    def send_report(query, ip)
      post "/api/v1/browser-reports?#{query}", headers: { 'User-Agent' => iphone }, env: { 'REMOTE_ADDR' => ip }
    end

    it 'takes 60 page loads from one IP in 10 minutes and throttles the 61st' do
      60.times do
        send_report('result=passed&touch=0', '10.0.0.4')
        expect(response).to have_http_status(:no_content)
      end

      send_report('result=passed&touch=0', '10.0.0.4')
      expect(response).to have_http_status(:too_many_requests)

      send_report('result=passed&touch=0', '10.0.0.5')
      expect(response).to have_http_status(:no_content)
    end

    it 'takes 10 alerts from one IP in an hour and throttles the 11th' do
      10.times do
        send_report('result=failed&tests=lookbehind&touch=0', '10.0.0.6')
        expect(response).to have_http_status(:no_content)
      end

      send_report('result=error&error=boom&touch=0', '10.0.0.6')
      expect(response).to have_http_status(:too_many_requests)

      # A passing report still gets through: the alert limit does not stop
      # the count.
      send_report('result=passed&touch=0', '10.0.0.6')
      expect(response).to have_http_status(:no_content)
    end

    # An app that did not load alerts the owner too, so it counts against
    # the same limit.
    it 'counts an app that did not load as an alert' do
      10.times do
        send_report('result=load_failed&error=x&touch=0', '10.0.0.7')
        expect(response).to have_http_status(:no_content)
      end

      send_report('result=load_failed&error=x&touch=0', '10.0.0.7')
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end

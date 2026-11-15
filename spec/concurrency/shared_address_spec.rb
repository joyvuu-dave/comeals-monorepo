# frozen_string_literal: true

require 'rails_helper'

# Many people on one address at once: the Common House iPad, or homes
# that share one internet connection (challenge 4). Rack::Attack counts
# every API request in one row per address and rule, so requests from
# one address that run at the same moment all add to the same row.
#
# Until #292 the rows were solid_cache entries. solid_cache adds with a
# read and then a write, and at SERIALIZABLE PostgreSQL refused all but
# one of the requests for a conflict. The failsafe turned that into "no
# count", and Rack::Attack wrote 1 over the count: 40 login tries at once
# were all let through, and 200 requests counted as 2 to 4. ThrottleStore
# adds in one statement at READ COMMITTED (ADR 0005 decision 11).
#
# Production runs one Puma thread, so two requests never overlap there
# today. More threads (challenge 4, option 2) would make them overlap.
RSpec.describe 'many requests from one address at the same moment', prosopite: false do
  include_context 'with no test transaction'
  include ActiveSupport::Testing::TimeHelpers

  # How many requests run at once. A method, not a constant: before(:all)
  # needs it too, and it has no let.
  def threads
    8
  end

  # Rack::Attack keys each count by its time window. A run that crossed a
  # window's edge would start the count again. So the clock is held one
  # second after an hour starts, the start of every rule's window.
  before { travel_to(Time.utc(2026, 4, 1, 12, 0, 1)) }

  before(:all) do
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @original_db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    ActiveRecord::Base.establish_connection(@original_db_config.merge(pool: threads + 4))
    Rails.application.eager_load!
    Rails.application.reload_routes_unless_loaded
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@original_db_config)
    # rubocop:enable RSpec/InstanceVariable
  end

  # The test environment counts nothing (spec/support/rack_attack.rb);
  # production counts in ThrottleStore, so that is what this gets.
  around do |example|
    original_attack_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ThrottleStore.new
    example.run
  ensure
    Rack::Attack.cache.store = original_attack_store
  end

  # Each thread sends `each` requests, all threads starting together.
  # The statuses, with any exception in place of a status.
  def send_at_once(each, &)
    gate = Queue.new
    workers = Array.new(threads) do
      Thread.new do
        gate.pop
        Array.new(each) do
          yield.first
        rescue StandardError => e
          "#{e.class}: #{e.message.lines.first&.strip}"
        end
      end
    end
    threads.times { gate << :go }
    workers.flat_map(&:value).tally
  end

  it 'answers every request, and counts every one against the address' do
    statuses = send_at_once(25) { Storm::RACK_TRANSPORT.call(:get, '/api/v1/version', {}, nil, '10.8.0.1') }

    expect(statuses).to eq(200 => threads * 25)
    expect(ThrottleCount.where('key LIKE ?', '%:api/ip:10.8.0.1').pluck(:count)).to eq([threads * 25])
  end

  # The login throttle allows 20 tries per address in 5 minutes
  # (config/initializers/rack_attack.rb), so of 40 tries only 20 get an
  # answer from the app.
  it 'refuses every login try past the 20th from one address, one at a time' do
    body = JSON.generate(email: 'nobody@example.com', password: 'wrong')
    statuses = Array.new(threads * 5) do
      Storm::RACK_TRANSPORT.call(:post, '/api/v1/residents/token', {}, body, '10.8.0.3').first
    end

    expect(statuses.count(429)).to eq((threads * 5) - 20)
  end

  it 'refuses every login try past the 20th from one address, even when they come at once' do
    body = JSON.generate(email: 'nobody@example.com', password: 'wrong')
    statuses = send_at_once(5) do
      Storm::RACK_TRANSPORT.call(:post, '/api/v1/residents/token', {}, body, '10.8.0.2')
    end

    expect(statuses.fetch(429, 0)).to eq((threads * 5) - 20)
  end
end

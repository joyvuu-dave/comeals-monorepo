# frozen_string_literal: true

require 'rails_helper'

# A spec that does not set a throttle store of its own must never be
# throttled, even when it swaps Rails.cache for a real store. Rack::Attack
# picks the store it counts in the first time anything asks for
# Rack::Attack.cache, and keeps it. Without spec/support/rack_attack.rb
# that was usually the first request that reached a throttle. If that
# request ran inside a spec like this one, Rack::Attack kept the spec's
# store, and its counts reached every later spec. In a run of
# spec/requests alone, the password-reset specs then answered 429 (#146).
# spec/support/rack_attack.rb picks the store before any spec runs.
#
# Without that file, this example fails when it runs alone, or after a
# spec that swapped in a store of its own (as in a run of spec/requests).
# In a full run, spec/concurrency/request_storm_spec.rb asks for the
# store before any spec swaps Rails.cache, so there this example passes
# either way.
RSpec.describe 'Rack::Attack counts between specs' do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  it 'does not count in a store that a spec swapped in for itself' do
    one_past_the_limit = Rack::Attack.throttles.fetch('password-reset/ip').limit + 1
    one_past_the_limit.times { post '/api/v1/residents/password-reset', params: { email: 'nobody@example.com' } }

    expect(response).not_to have_http_status(:too_many_requests)
  end
end

# frozen_string_literal: true

# Rack::Attack counts throttled requests in a cache store. It picks that
# store once, the first time anything asks for Rack::Attack.cache
# (usually the first request that reaches a throttle): whatever
# Rails.cache is at that moment. In the test environment Rails.cache is a
# null store, which keeps no counts, so no spec is ever throttled unless
# it sets a store of its own (rack_attack_spec.rb does).
#
# But many request specs swap Rails.cache for a memory store while they
# run. When one of them made the first throttled request of a run,
# Rack::Attack kept that memory store for the rest of the run, and counts
# from one spec reached the next. A run of spec/requests alone answered
# 429 to the password-reset specs (#146). Clearing Rails.cache before
# each example does not help: by then Rails.cache is the null store
# again, and the memory store Rack::Attack holds is no longer in it.
#
# So the store is picked here, before any spec runs, and the order of the
# specs no longer decides it.
RSpec.configure do |config|
  config.before(:suite) { Rack::Attack.cache.store = Rails.cache }
end

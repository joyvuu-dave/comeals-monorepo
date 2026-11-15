# typed: true
# frozen_string_literal: true

# The store Rack::Attack keeps its request counts in
# (config/initializers/rack_attack.rb). The counts are rows in
# throttle_counts (ThrottleCount), not cache entries (#292).
#
# These are the four calls Rack::Attack::Cache makes (rack-attack 6.8.0,
# lib/rack/attack/cache.rb). `expires_in` is the seconds left in the
# rule's time window. Rack::Attack.reset! needs a fifth, delete_matched,
# which this store does not have; empty the table instead.
class ThrottleStore
  # The store for an app whose cache is `cache`: this one, unless the
  # cache keeps nothing, and then the cache itself, so nothing is counted.
  def self.for(cache)
    cache.is_a?(ActiveSupport::Cache::NullStore) ? cache : new
  end

  # The new count. Never nil: Rack::Attack takes nil to mean "no count
  # yet" and writes 1 over the count, which is how #292 lost counts.
  def increment(key, amount = 1, expires_in:)
    ThrottleCount.add(key, amount, expires_at: Time.current + expires_in)
  end

  def write(key, value, expires_in:)
    ThrottleCount.set(key, Integer(value), expires_at: Time.current + expires_in)
  end

  def read(key)
    ThrottleCount.current(key)
  end

  def delete(key)
    ThrottleCount.forget(key)
  end
end

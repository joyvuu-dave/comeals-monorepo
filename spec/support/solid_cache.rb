# frozen_string_literal: true

# Builds the SolidCache::Store that specs run against.
#
# The one difference from production is expiry_method: :job.
#
# After a write, solid_cache trims old entries, and by default it does that
# on a thread of its own (SolidCache::Store::Expiry, expiry_method: :thread).
# That thread talks to the database. Specs run inside a transaction on a
# single connection that RSpec pins and locks to the example's thread, and
# when the example ends RSpec rolls that transaction back, unlocks the
# connection, and hands it to the next example. A trim that is still running
# at that moment ends up sharing one Postgres connection with the next
# example, with the lock already gone. Two threads sending statements down
# one connection is not something the driver can survive: it waits for a
# result another thread already read, and waits forever. That is what hung
# CI for six hours at a time, and it only showed up now and then because
# only about one write in fifty starts a trim.
#
# :job hands the trim to Active Job instead of a thread, and the test queue
# adapter (config/environments/test.rb) parks it in an array where it never
# runs. Nothing these specs are about changes — read, write, delete, fetch,
# and increment all still hit real rows in the real table.
module SolidCacheHelper
  def build_solid_cache_store(namespace:)
    SolidCache::Store.new(namespace: namespace, expiry_method: :job)
  end
end

RSpec.configure do |config|
  config.include SolidCacheHelper
end

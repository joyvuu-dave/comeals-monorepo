# typed: true
# frozen_string_literal: true

# Refuse to boot when the database pool is smaller than the threads that
# will draw from it.
#
# The pool and the thread count are two different settings on purpose
# (config/database.yml says why), and that is exactly what makes them easy
# to drift apart: raise RAILS_MAX_THREADS for throughput, forget
# RAILS_DB_POOL, and every busy moment becomes
# ActiveRecord::ConnectionTimeoutError — a 503 to whoever was unlucky
# (ApiController), for a reason that is a setting rather than a bug.
#
# The rule is the one already written in prose in config/database.yml: one
# connection per Puma thread, plus one for the thread solid_cache uses to
# trim old entries. Nothing else in the web dyno needs one — Solid Queue
# runs in forked processes with pools of their own (config/queue.yml, and
# the Puma plugin's default fork mode), so its jobs never compete here.
#
# Boot-time, in every environment, like
# config/initializers/verify_transaction_isolation.rb: a deploy with the
# wrong numbers fails its release check instead of serving traffic.
module DatabasePoolCheck
  extend T::Sig

  # solid_cache's trim thread (config/solid_cache.yml leaves expiry_method
  # at its default, :thread).
  BACKGROUND_THREADS = 1

  sig { params(pool: Integer, threads: Integer).void }
  def self.call(pool:, threads:)
    needed = threads + BACKGROUND_THREADS
    return if pool >= needed

    raise "Database pool of #{pool} is too small for #{threads} Puma thread(s). " \
          "Set RAILS_DB_POOL to at least #{needed} — one connection per thread, plus one for " \
          'the thread solid_cache trims with. See config/database.yml and lib/database_pool_check.rb.'
  end

  # The numbers as this process actually resolved them: the pool from the
  # database configuration (so a mistake in database.yml counts too, not
  # only one in the environment), the threads from the variable
  # config/puma.rb reads.
  sig { void }
  def self.verify!
    # max_connections, not pool: pool is deprecated in Rails 8.1 and gone
    # in 8.2.
    call(pool: ActiveRecord::Base.connection_db_config.max_connections || 0,
         threads: ENV.fetch('RAILS_MAX_THREADS', 1).to_i)
  end
end

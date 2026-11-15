# typed: false
# frozen_string_literal: true

# solid_cache keeps its entries in the primary database (see AGENTS.md), so
# every cache write is an ordinary transaction against the same database as
# the money code. Once the app runs at
# SERIALIZABLE, PostgreSQL can refuse any of them for a conflict.
#
# solid_cache already treats a refusal as transient when it arrives as
# ActiveRecord::Deadlocked: the failsafe logs it, reports it, and returns a
# miss. It does not treat ActiveRecord::SerializationFailure the same way,
# because the gem was written for READ COMMITTED, where that error does not
# happen. The two are the same problem with the same answer — both are
# subclasses of ActiveRecord::TransactionRollbackError, and PostgreSQL picks
# between them by which rule it broke.
#
# Without this line a conflict on a cache entry becomes a 500 on a request
# that has nothing to do with money. A cache miss is the right answer instead:
# nothing was written, and reading through to the source is always correct.
#
# A miss is not the right answer for a count, so Rack::Attack's counts are not
# in solid_cache. They were until #292: a count refused for a conflict became
# "no count", and Rack::Attack wrote 1 over it. They are rows in
# throttle_counts now (ThrottleStore, ADR 0005 decision 11).
#
# The constant is a plain array and is not frozen, and the failsafe splats it
# at rescue time, so appending to it works. Checked against solid_cache 1.0.10.
# spec/lib/solid_cache/store_spec.rb pins both facts.
#
# See docs/adr/0005-serializable-by-default.md.
# uniq! keeps one copy if something has already added it.
errors = SolidCache::Store::Failsafe::TRANSIENT_ACTIVE_RECORD_ERRORS
errors << ActiveRecord::SerializationFailure
errors.uniq!

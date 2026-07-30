# frozen_string_literal: true

# solid_cache keeps its entries in the primary database (see CLAUDE.md), so
# every cache write and every Rack::Attack counter is an ordinary transaction
# against the same database as the money code. Once the app runs at
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
# Without this line a conflict on a rate-limit counter becomes a 500 on a
# request that has nothing to do with money. A cache miss is the right answer
# instead: nothing was written, and reading through to the source is always
# correct.
#
# The constant is a plain array and is not frozen, and the failsafe splats it
# at rescue time, so appending to it works. Checked against solid_cache 1.0.10.
# spec/lib/solid_cache/store_spec.rb pins both facts.
#
# See docs/adr/0005-serializable-by-default.md.
errors = SolidCache::Store::Failsafe::TRANSIENT_ACTIVE_RECORD_ERRORS
errors << ActiveRecord::SerializationFailure unless errors.include?(ActiveRecord::SerializationFailure)

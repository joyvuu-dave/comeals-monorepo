# typed: true
# frozen_string_literal: true

# Gives a database refusal the model's own words. A model that checks a
# rule in Ruby, with a database constraint behind it, can still be
# refused by the database: another write changed the rows after the
# model checked them. Two cases in this app (#149):
#
# - Two copies of one event or booking (a console beside a request).
#   Each changes one time and passes its own check, and Rails writes
#   only the column that changed, so the row would end before it starts.
#   A CHECK refuses the second save.
# - Two bookings for the same time, saved at the same moment. Neither
#   sees the other when it checks that the time is free, and the EXCLUDE
#   refuses the second. PostgreSQL reports that as an exclusion
#   violation even at SERIALIZABLE, not as a serialization failure that
#   RetryOnConflict would try again.
#
# Without this the refusal is an exception: a 500 from the API, an error
# page in admin. With it, save returns false with the message the model
# gives when it sees the other write in time, and save! raises
# ActiveRecord::RecordNotSaved. A constraint the model names no message
# for still raises.
#
# The write runs in a savepoint, so a refused statement leaves a
# transaction the caller opened usable. The save's callbacks run in that
# savepoint too, and LiveUpdate keeps one batch per innermost
# transaction. So when one transaction saves two of these rows, each
# save flushes its own batch, and a month both rows are in is pushed
# twice. A second push only makes a screen fetch again. No path in the
# app saves two of these rows in one transaction: each request saves
# one row, and a destroy opens no savepoint.
module ConstraintMessages
  extend ActiveSupport::Concern
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  private

  # Every save, create and update goes through this method
  # (ActiveRecord::Persistence), after the validations and around the
  # save callbacks.
  def create_or_update(**, &)
    transaction(requires_new: true) { super }
  rescue ActiveRecord::CheckViolation, ActiveRecord::ExclusionViolation => e
    message = constraint_messages[constraint_name(e)]
    raise unless message

    errors.add(:base, message)
    false
  end

  # The server names the constraint in every violation it reports.
  def constraint_name(error)
    T.must(T.cast(error.cause, PG::Error).result).error_field(PG::Constants::PG_DIAG_CONSTRAINT_NAME)
  end
end

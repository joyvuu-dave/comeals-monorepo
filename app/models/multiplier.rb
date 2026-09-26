# typed: true
# frozen_string_literal: true

# The one place that says what a multiplier value means. This is the
# analogue of MealLedger's "Signs" section: the meaning is set once, here,
# and every place that assigns or compares a multiplier reads these names.
#
# The unit story: a multiplier counts half-price units. Full price is 2
# units so that half price is a whole number (1), and free is 0. The values
# must be integers because the ledger sums them into a divisor — a meal's
# cost is split by the total number of units at the table.
#
# MealLedger must NOT read this module. The ledger sums multipliers and
# divides by the total; it does not know or care that 2 means "one adult".
# That ignorance is the design: pricing policy lives here, in
# Community#multiplier_for_age and Resident#multiplier_on; arithmetic
# lives in the ledger.
# spec/models/multiplier_spec.rb pins this.
#
# The database default for guests.multiplier is FULL, but a schema default
# cannot reference a Ruby constant, so it is written as the literal 2 in
# the schema. spec/models/multiplier_spec.rb pins it to this module so it
# cannot drift. (residents.multiplier is an ignored column, kept one
# release for the rollback story; a resident's band is computed.)
module Multiplier
  FREE = 0
  HALF = 1
  FULL = 2
end

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
  extend T::Sig

  FREE = 0
  HALF = 1
  FULL = 2

  # The two prices a guest can have: an adult or a child. Free is a price
  # only a resident's age gives. Adult first, because the admin meal form
  # lists them in this order and a new guest is an adult. The Guest model
  # and the guests_multiplier_adult_or_child CHECK refuse anything else,
  # so the form can always show the price a guest has.
  GUEST_PRICES = T.let([FULL, HALF].freeze, T::Array[Integer])

  # The one rendering of a price: 2 is an adult, 1 a child, 0 a child who
  # eats free (the words the community form uses for the age rule), and
  # anything else a multiple of an adult ("Adult x 1.5"). Every admin
  # page that names a price calls this through
  # ApplicationHelper#price_category_label, and the meal history
  # (AuditDescription) calls it directly. Five hand-written copies once
  # disagreed (#51), and one of them showed a 1.5x adult as a plain
  # "Adult". A free child showed as "Adult x 0" until #99.
  sig { params(multiplier: Integer).returns(String) }
  def self.label(multiplier)
    return 'Child (free)' if multiplier == FREE
    return 'Child' if multiplier == HALF
    return 'Adult' if multiplier == FULL

    adults = ActiveSupport::NumberHelper.number_to_rounded(BigDecimal(multiplier) / FULL,
                                                           precision: 1, strip_insignificant_zeros: true)
    "Adult x #{adults}"
  end
end

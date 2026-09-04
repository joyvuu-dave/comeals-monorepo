# typed: true
# frozen_string_literal: true

# View formatting only. Name shortening lives in ResidentNameShortener
# and audit sentences in AuditDescription — both used to sit here, which
# put model queries in a view module and re-ran the name pluck once per
# serializer instance (#51).
module ApplicationHelper
  extend T::Helpers

  requires_ancestor { ActionView::Base }

  include ActiveSupport::NumberHelper

  # The one rendering of a price category. A multiplier of 2 is one
  # adult, 1 is a child; anything else shows as a multiple of an adult
  # ("Adult x 1.5"). Every screen that names a category calls this —
  # five hand-written copies of this block once disagreed (#51), and
  # one of them showed a 1.5x adult as a plain "Adult".
  def price_category_label(multiplier)
    return 'Child' if multiplier == Multiplier::HALF
    return 'Adult' if multiplier == Multiplier::FULL

    "Adult x #{number_with_precision(multiplier.to_f / Multiplier::FULL,
                                     precision: 1, strip_insignificant_zeros: true)}"
  end

  # The child pricing rule as one plain sentence, built from the community's
  # two configured ages. Shown next to the age fields on the community form
  # and next to the price category field on the resident form, so the ages
  # an admin reads always come from the record, never from a copied number.
  # The age bands are defined on Community (see "Child pricing ages" there).
  def child_pricing_rule_sentence(community)
    free_below = community.free_below_age
    full_at = community.full_price_age

    if full_at.zero?
      'Everyone pays full price.'
    elsif free_below.zero?
      "Children under #{full_at} pay half price, and everyone #{full_at} and older pays full price."
    elsif free_below == full_at
      "Children under #{free_below} eat free, and everyone #{free_below} and older pays full price."
    else
      "Children under #{free_below} eat free, children #{free_below} to #{full_at - 1} pay half price, " \
        "and everyone #{full_at} and older pays full price."
    end
  end

  # A meal cost in an admin table cell: the dollar amount, or blank.
  # Blank covers two cases on purpose: the value is zero, or the meal
  # was settled before line items existed and MealCostSummary has
  # nothing for it. Both mean "no amount to show", not "$0.00".
  def meal_cost_cell(meal, field)
    summary = MealCostSummary.for(meal)
    return if summary.nil?

    value = summary.public_send(field)
    number_to_currency(value) unless value.zero?
  end
end

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

  # Whether this page may name the admin who made a correction or a mark.
  # A signed-in admin sees who. The read-only token sees what was done and
  # when, because its links are mailed to cooks and the common house, and
  # a mailed link must not show admin emails (ADR 0004 §3).
  def names_admins?
    !Current.read_only_admin_token
  end

  # Whether this page may show a resident's birthday. A signed-in admin
  # sees it and edits it. The read-only token does not: its links are
  # mailed to the whole community, and a mailed link must not be a list
  # of everyone's date of birth (ADR 0004 §3). The token still sees the
  # price band. Resident leaves the birthday out of the JSON and the
  # filters for the token itself (Resident::HIDDEN_FROM_THE_TOKEN).
  def shows_birthdays?
    !Current.read_only_admin_token
  end

  # The words for a price ("Adult", "Child", "Child (free)"). They live
  # in Multiplier.label, because the meal history uses them too.
  def price_category_label(multiplier)
    Multiplier.label(multiplier)
  end

  # The child pricing rule as one plain sentence, built from the community's
  # two configured ages. Shown next to the age fields on the community form
  # and under the "This person is" radio on the resident form, so the ages
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
  #
  # now: true reads the meal's rows as they are now (MealCostSummary.now),
  # for the meal's own page, where a corrected settled meal shows what it
  # costs after the correction.
  def meal_cost_cell(meal, field, now: false)
    summary = now ? MealCostSummary.now(meal) : MealCostSummary.for(meal)
    return if summary.nil?

    value = summary.public_send(field)
    number_to_currency(value) unless value.zero?
  end
end

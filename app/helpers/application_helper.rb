# frozen_string_literal: true

# View formatting only. Name shortening lives in ResidentNameShortener
# and audit sentences in AuditDescription — both used to sit here, which
# put model queries in a view module and re-ran the name pluck once per
# serializer instance (#51).
module ApplicationHelper
  include ActiveSupport::NumberHelper

  # The one rendering of a price category. A multiplier of 2 is one
  # adult, 1 is a child; anything else shows as a multiple of an adult
  # ("Adult x 1.5"). Every screen that names a category calls this —
  # five hand-written copies of this block once disagreed (#51), and
  # one of them showed a 1.5x adult as a plain "Adult".
  def price_category_label(multiplier)
    return 'Child' if multiplier == 1
    return 'Adult' if multiplier == 2

    "Adult x #{number_with_precision(multiplier.to_f / 2, precision: 1, strip_insignificant_zeros: true)}"
  end
end

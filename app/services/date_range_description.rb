# typed: true
# frozen_string_literal: true

# The human-readable form of a date range, shown wherever a period is named
# (a rotation's title, a settlement statement's section heading). Month
# names, not ISO dates, and no repeated year or month when they are the same:
#
#   no dates      -> ""
#   one day       -> "Jul 16, 2026"
#   same month    -> "Jul 16–28, 2026"
#   same year     -> "Jul 16 – Aug 13, 2026"
#   across years  -> "Dec 14, 2026 – Jan 11, 2027"
#
# The dash is an en dash: closed up between two day numbers, spaced when
# either side contains a space.
module DateRangeDescription
  def self.for(first, last)
    return '' if first.nil?

    if first == last
      first.strftime('%b %-d, %Y')
    elsif [first.year, first.month] == [last.year, last.month]
      "#{first.strftime('%b %-d')}–#{last.day}, #{first.year}"
    elsif first.year == last.year
      "#{first.strftime('%b %-d')} – #{last.strftime('%b %-d')}, #{first.year}"
    else
      "#{first.strftime('%b %-d, %Y')} – #{last.strftime('%b %-d, %Y')}"
    end
  end
end

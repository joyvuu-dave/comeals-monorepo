# frozen_string_literal: true

# Shortens a resident's full name to the shortest form that is still
# unique: first name alone if no one shares it, first name plus last
# initial if that settles it, the full name otherwise. The full name is
# always a safe last step because resident names are unique — the
# case-insensitive index index_residents_on_lower_name.
#
# The name list is every row in the residents table, and that is the
# right list twice over:
#   - There is exactly one community. The communities table can never
#     hold a second row (singleton_guard, a constant 0 with a unique
#     index — see Community#enforce_singleton), so no community scoping
#     is needed here or anywhere else in the app.
#   - Inactive residents count on purpose. A moved-out "Alice Smith"
#     still appears in old audit lines, so the current Alice keeps her
#     longer form and old lines stay unambiguous.
#
# Only the first and last words of a name take part. Middle names never
# help tell people apart here: "Mary Jane Smith" and "Mary Jane Jones"
# shorten to "Mary S" and "Mary J", and when even first word + last
# initial clash, the fallback is the whole name, middle words included.
#
# The name list is read once per request (through Current, which Rails
# resets between requests). Before this existed the lookup lived in a
# helper whose memo was per-including-instance — and a serializer
# collection builds one instance per record, so a calendar render
# re-ran the pluck for every row (#51).
class ResidentNameShortener
  def self.short(name)
    Current.resident_names ||= Resident.pluck(:name)
    new(Current.resident_names).short(name)
  end

  def initialize(names)
    @names = names
  end

  def short(name)
    return '' if name.blank?

    first = first_word(name)
    last = last_word(name)

    # A bare first name is already as short as it gets.
    return name if last.nil?

    # First name is unique: use it alone.
    same_first = @names.select { |n| same?(first_word(n), first) }
    return first if same_first.one?

    # Shared first name: last initial if that is unambiguous, else the
    # full name.
    initial_unique = same_first.none? do |n|
      n != name && same?(last_word(n)&.slice(0, 1), last[0])
    end
    initial_unique ? "#{first} #{last[0]}" : name
  end

  private

  def first_word(name)
    name.split.first
  end

  # nil for a single-word name — it has no last name at all, which is
  # not the same as sharing an initial with someone.
  def last_word(name)
    words = name.split
    words.length > 1 ? words.last : nil
  end

  # Case-insensitive, because name uniqueness is case-insensitive too:
  # "alice smith" and "Alice Jones" share a first name.
  def same?(left, right)
    left.to_s.casecmp?(right.to_s)
  end
end

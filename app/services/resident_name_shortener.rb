# frozen_string_literal: true

# Shortens a resident's full name to the shortest form that is still
# unique in this community: first name if no one shares it, first name
# plus last initial if that settles it, full name otherwise.
#
# The community's name list is read once per request (through Current,
# which Rails resets between requests). Before this existed the lookup
# lived in a helper whose memo was per-including-instance — and a
# serializer collection builds one instance per record, so a calendar
# render re-ran the pluck for every row (#51).
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

    first, last = name.split

    # A bare first name is already as short as it gets.
    return name if last.nil?

    # First name is unique: use it alone.
    return first if @names.one? { |n| n.split[0] == first }

    # Shared first name: last initial if that is unambiguous, else the
    # full name.
    same_first = @names.select { |n| n.split[0] == first }
    initial_unique = same_first.none? { |n| n != name && n.split[1]&.start_with?(last[0]) }
    initial_unique ? "#{first} #{last[0]}" : "#{first} #{last}"
  end
end

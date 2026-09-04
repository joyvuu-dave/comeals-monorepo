# typed: true

# Icalendar builds the X-WR-* property setters with method_missing, so the
# gem RBI does not list them. Only the ones the app calls are declared.
class Icalendar::Calendar
  sig { params(value: String).void }
  def x_wr_calname=(value); end
end

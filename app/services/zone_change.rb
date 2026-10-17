# typed: true
# frozen_string_literal: true

# What a change of the community's time zone would do to the calendar,
# read before the change is saved (#173). The admin community form shows
# it and asks for a second submit.
#
# Events and common house bookings are stored as instants, and a new zone
# keeps the instants. What people see is the clock time in the
# community's zone, and that moves: 20:00 in Los Angeles is 23:00 in New
# York. So a timed event or a booking can move past midnight and end on
# the next day, and an all-day event, saved as midnight, can show on the
# day before (midnight in Los Angeles is 21:00 or 22:00 the day before
# in Honolulu). Meals do not move: a meal is a date, and its start time
# is read from the dinner start times in whatever zone is set.
#
# Every row is read, past ones too, because the calendar shows them all.
# Two plucks, read in Ruby with the same zone rules the models use
# (Community#date_of).
class ZoneChange
  extend T::Sig

  # One event or booking that would end on the day after it starts.
  # `day` is the day it starts in the current zone, the day people know.
  Row = Struct.new(:kind, :title, :day, keyword_init: true)

  # How many crossing rows the form lists.
  LISTED = 10

  sig { params(community: Community, zone: String).void }
  def initialize(community, zone)
    @old_zone = T.let(T.must(ActiveSupport::TimeZone[T.must(community.timezone)]), ActiveSupport::TimeZone)
    @new_zone = T.let(T.must(ActiveSupport::TimeZone[zone]), ActiveSupport::TimeZone)
    @timed = T.let(nil, T.nilable(T::Array[[String, T.nilable(String), Time, Time]]))
    @all_day_starts = T.let(nil, T.nilable(T::Array[Time]))
  end

  # Timed events and bookings whose start or end shows at another clock
  # time. The clock time moves exactly when the two zones' UTC offsets
  # differ at that instant.
  sig { returns(Integer) }
  def moved_count
    timed.count { |_kind, _title, start, finish| moves?(start) || moves?(finish) }
  end

  # All-day events that would show on another day.
  sig { returns(Integer) }
  def all_day_moved_count
    all_day_starts.count { |start| day_in(@old_zone, start) != day_in(@new_zone, start) }
  end

  sig { returns(Integer) }
  def crossing_count
    crossing_rows.size
  end

  # The first LISTED rows that would end on the day after they start,
  # earliest start first.
  sig { returns(T::Array[Row]) }
  def crossing
    crossing_rows.first(LISTED).map do |kind, title, start, _finish|
      Row.new(kind: kind, title: title, day: day_in(@old_zone, start))
    end
  end

  sig { returns(T::Boolean) }
  def any?
    moved_count.positive? || all_day_moved_count.positive?
  end

  private

  sig { returns(T::Array[[String, T.nilable(String), Time, Time]]) }
  def crossing_rows
    timed.reject { |_kind, _title, start, finish| day_in(@new_zone, start) == day_in(@new_zone, finish) }
  end

  sig { params(time: Time).returns(T::Boolean) }
  def moves?(time)
    time.in_time_zone(@old_zone).utc_offset != time.in_time_zone(@new_zone).utc_offset
  end

  sig { params(zone: ActiveSupport::TimeZone, time: Time).returns(Date) }
  def day_in(zone, time)
    time.in_time_zone(zone).to_date
  end

  # Every timed event (not all day, with an end) and every booking, as
  # [kind, title, start, end], earliest start first (then by kind and
  # title, so two rows that start together keep one order).
  sig { returns(T::Array[[String, T.nilable(String), Time, Time]]) }
  def timed
    @timed ||= begin
      events = Event.where(allday: false).where.not(end_date: nil)
                    .pluck(:title, :start_date, :end_date).map { |row| ['Event', *row] }
      bookings = CommonHouseReservation.pluck(:title, :start_date, :end_date)
                                       .map { |row| ['Common house booking', *row] }
      (events + bookings).sort_by { |kind, title, start, _finish| [start, kind, title.to_s] }
    end
  end

  sig { returns(T::Array[Time]) }
  def all_day_starts
    @all_day_starts ||= Event.where(allday: true).pluck(:start_date)
  end
end

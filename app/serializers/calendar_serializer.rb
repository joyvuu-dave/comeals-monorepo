# frozen_string_literal: true

# Serializes a community's calendar month for the frontend. Build it with
# `params: { month:, year:, start_date:, end_date:, month_int_array: }`.
#
# CACHING: The calendar response is cached by CommunitiesController#calendar
# via Rails.cache.fetch. Any model whose data appears in this serializer
# MUST invalidate the cache when its data changes, or users will see stale
# calendars. Call community.invalidate_calendar_cache(date) where `date` is
# a date that falls within the affected calendar month.
#
# Current invalidation points (if you add a new one, add it to this list):
#
#   Model                      Trigger                         How
#   -------------------------  ------------------------------  ---------------------------------
#   Meal                       after_action in controller      Meal#trigger_pusher
#   Bill                       after_action in controller      (through Meal#trigger_pusher)
#   MealResident               after_action in controller      (through Meal#trigger_pusher)
#   Guest                      after_action in controller      (through Meal#trigger_pusher)
#   Event                      after_commit :trigger_pusher    community.trigger_pusher(start_date)
#   CommonHouseReservation     after_commit :trigger_pusher    community.trigger_pusher(start_date)
#   GuestRoomReservation       after_commit :trigger_pusher    community.trigger_pusher(date)
#   Rotation                   after_commit                    community.invalidate_calendar_cache
#   Resident (birthday)        after_commit                    community.invalidate_calendar_cache
#
# The deploy script (bin/deploy) also flushes the entire cache on every deploy.
class CalendarSerializer
  include Alba::Resource

  attributes :id,
             :month,
             :year

  # Each collection below is a query scoped to the weeks on screen, so it
  # is an attribute block that runs the query and serializes the rows,
  # not a `many` on a model association.
  attribute :meals do |community|
    MealSerializer.new(meals_in_range(community)).to_h
  end

  attribute :bills do |community|
    BillSerializer.new(bills_in_range(community)).to_h
  end

  attribute :rotations do |community|
    RotationSerializer.new(rotations_in_range(community)).to_h
  end

  attribute :birthdays do |community|
    ResidentBirthdaySerializer.new(birthdays_in_range(community)).to_h
  end

  attribute :common_house_reservations do |community|
    CommonHouseReservationSerializer.new(common_house_reservations_in_range(community)).to_h
  end

  attribute :guest_room_reservations do |community|
    GuestRoomReservationSerializer.new(guest_room_reservations_in_range(community)).to_h
  end

  attribute :events do |community|
    EventSerializer.new(events_in_range(community)).to_h
  end

  def month(_community)
    params.fetch(:month)
  end

  def year(_community)
    params.fetch(:year)
  end

  # Every collection here is ordered deterministically. Without explicit ORDER
  # BY, Postgres may return rows in arbitrary order (especially after updates
  # that reshuffle heap tuples), which would change the ETag digest of the
  # cached result even when the underlying data is identical. Ordering by :id
  # is cheap (PK B-tree) and gives the cache-miss recompute path a stable
  # fingerprint.

  def meals_in_range(community)
    community.meals
             .where(date: start_date..)
             .where(date: ..end_date)
             .order(:id)
             .preload(:meal_residents, :guests)
  end

  def bills_in_range(community)
    community.bills
             .includes(:meal, { resident: :unit })
             .joins(:meal)
             .where(meals: { date: start_date.. })
             .where(meals: { date: ..end_date })
             .order('bills.id')
  end

  def rotations_in_range(community)
    rotation_ids = meals_in_range(community).where.not(rotation_id: nil)
                                            .pluck(:rotation_id).uniq
    Rotation.where(id: rotation_ids).order(:id).preload(:meals).to_a
  end

  def birthdays_in_range(community)
    community.residents.active
             .where('extract(month from birthday) in (?)', params.fetch(:month_int_array))
             .order(:id)
  end

  def common_house_reservations_in_range(community)
    community.common_house_reservations
             .includes({ resident: :unit })
             .where(start_date: start_date..)
             .where(start_date: ..end_date)
             .order(:id)
  end

  def guest_room_reservations_in_range(community)
    community.guest_room_reservations
             .includes({ resident: :unit })
             .where(date: start_date..)
             .where(date: ..end_date)
             .order(:id)
  end

  def events_in_range(community)
    community.events
             .where(start_date: start_date..)
             .where(start_date: ..end_date)
             .or(community.events
                          .where(end_date: start_date..)
                          .where(end_date: ..end_date))
             .or(community.events
                          .where(start_date: ...start_date)
                          .where('end_date > ?', end_date))
             .order(:id)
  end

  private

  def start_date
    params.fetch(:start_date)
  end

  def end_date
    params.fetch(:end_date)
  end
end

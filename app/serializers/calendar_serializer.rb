# frozen_string_literal: true

# Serializes a community's calendar month for the frontend.
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
class CalendarSerializer < ActiveModel::Serializer
  attributes :id,
             :month,
             :year

  has_many :meals, serializer: MealSerializer
  has_many :bills, serializer: BillSerializer
  has_many :rotations, serializer: RotationSerializer
  has_many :birthdays, serializer: ResidentBirthdaySerializer
  has_many :common_house_reservations, serializer: CommonHouseReservationSerializer
  has_many :guest_room_reservations, serializer: GuestRoomReservationSerializer
  has_many :events, serializer: EventSerializer

  def month
    instance_options[:month]
  end

  def year
    instance_options[:year]
  end

  # Every collection here is ordered deterministically. Without explicit ORDER
  # BY, Postgres may return rows in arbitrary order (especially after updates
  # that reshuffle heap tuples), which would change the ETag digest of the
  # cached result even when the underlying data is identical. Ordering by :id
  # is cheap (PK B-tree) and gives the cache-miss recompute path a stable
  # fingerprint.

  def meals
    object.meals
          .where(date: (instance_options[:start_date])..)
          .where(date: ..(instance_options[:end_date]))
          .order(:id)
          .preload(:meal_residents, :guests)
  end

  def bills
    object.bills
          .includes(:meal, { resident: :unit })
          .joins(:meal)
          .where(meals: { date: (instance_options[:start_date]).. })
          .where(meals: { date: ..(instance_options[:end_date]) })
          .order('bills.id')
  end

  def rotations
    rotation_ids = meals.where.not(rotation_id: nil)
                        .pluck(:rotation_id).uniq
    Rotation.where(id: rotation_ids).order(:id).preload(:meals).to_a
  end

  def birthdays
    object.residents.active
          .where('extract(month from birthday) in (?)', instance_options[:month_int_array])
          .order(:id)
  end

  def common_house_reservations
    object.common_house_reservations
          .includes({ resident: :unit })
          .where(start_date: (instance_options[:start_date])..)
          .where(start_date: ..(instance_options[:end_date]))
          .order(:id)
  end

  def guest_room_reservations
    object.guest_room_reservations
          .includes({ resident: :unit })
          .where(date: (instance_options[:start_date])..)
          .where(date: ..(instance_options[:end_date]))
          .order(:id)
  end

  def events
    object.events
          .where(start_date: (instance_options[:start_date])..)
          .where(start_date: ..(instance_options[:end_date]))
          .or(object.events
                    .where(end_date: (instance_options[:start_date])..)
                    .where(end_date: ..(instance_options[:end_date])))
          .or(object.events
                    .where(start_date: ...(instance_options[:start_date]))
                    .where('end_date > ?', instance_options[:end_date]))
          .order(:id)
  end
end

# frozen_string_literal: true

# Serializes a community's calendar month for the frontend. Build it with
# `params: { month:, year:, start_date:, end_date:, month_int_array: }`.
#
# CACHING: CommunitiesController#calendar caches this month for an hour
# under a version read from the rows (Community#calendar_cache_version).
# Two things keep a cached month right, and a model that appears here
# must be in both:
#
#   1. The version. It is the row count and newest updated_at of every
#      table drawn here, so a write through the model is a miss for the
#      next reader — even a write that lands while a request is still
#      building the month. The tables are listed in
#      Community#calendar_cache_version; a new table here goes there.
#   2. The push. Clients refetch only when told. Every model here notes
#      itself in LiveUpdate from its save and destroy callbacks (and
#      after_remove for rotation membership), which deletes the entry
#      and pushes the month's channel after commit. A new model here
#      needs those callbacks; spec/requests/api/v1/live_update_contract_spec.rb
#      is where its case goes.
#
#   Model                      Version sees it through        Push
#   -------------------------  -----------------------------  -----------------------------
#   Meal                       meals.updated_at               Meal#note_live_update
#   Bill, MealResident, Guest  meals.updated_at (touch: true) NotesMealLiveUpdate
#   Rotation                   rotations.updated_at           Rotation#note_live_update
#   Event                      events.updated_at              Event#note_live_update
#   CommonHouseReservation     its updated_at                 #note_live_update
#   GuestRoomReservation       its updated_at                 #note_live_update
#   Resident, Unit             their updated_at               LiveUpdate.residents (the
#                                                             residents channel; the client
#                                                             drops every cached month)
#
# The deploy script (bin/deploy) also flushes the entire cache on every deploy.
class CalendarSerializer
  include Alba::Resource

  attributes :id,
             :month,
             :year,
             # The community's zone rides with every month: the SPA computes every
             # time it shows and "today" from a zone it got at login, and this is
             # how a changed zone reaches a tab that is already open.
             :timezone

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
             .where(start_date: window_start..)
             .where(start_date: ..window_end)
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
             .where(start_date: window_start..)
             .where(start_date: ..window_end)
             .or(community.events
                          .where(end_date: window_start..)
                          .where(end_date: ..window_end))
             .or(community.events
                          .where(start_date: ...window_start)
                          .where('end_date > ?', window_end))
             .order(:id)
  end

  private

  def start_date
    params.fetch(:start_date)
  end

  def end_date
    params.fetch(:end_date)
  end

  # The window's dates are strings. Compared with a date column that is
  # fine. Compared with a datetime column, `..end_date` means midnight
  # at the start of the last day, so an event at 10:00 that day was
  # left out (#79). The datetime queries compare against these instants
  # instead, the same ones Community#calendar_cache_version uses.
  def window_start
    Time.zone.parse(start_date).beginning_of_day
  end

  def window_end
    Time.zone.parse(end_date).end_of_day
  end
end

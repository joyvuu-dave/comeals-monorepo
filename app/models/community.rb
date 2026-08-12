# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id                 :bigint           not null, primary key
#  cap                :decimal(12, 8)
#  meals_per_rotation :integer          default(12), not null
#  name               :string           not null
#  schedule           :jsonb            not null
#  singleton_guard    :integer          default(0), not null
#  timezone           :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_communities_on_name             (name) UNIQUE
#  index_communities_on_singleton_guard  (singleton_guard) UNIQUE
#

class Community < ApplicationRecord
  SUPPORTED_TIMEZONES = {
    'Hawaii' => 'Pacific/Honolulu',
    'Alaska' => 'America/Juneau',
    'Pacific Time (US & Canada)' => 'America/Los_Angeles',
    'Mountain Time (US & Canada)' => 'America/Denver',
    'Arizona' => 'America/Phoenix',
    'Central Time (US & Canada)' => 'America/Chicago',
    'Eastern Time (US & Canada)' => 'America/New_York',
    'Atlantic Time (Canada)' => 'America/Halifax',
    'London' => 'Europe/London',
    'Paris' => 'Europe/Paris',
    'Berlin' => 'Europe/Berlin',
    'Helsinki' => 'Europe/Helsinki',
    'Tokyo' => 'Asia/Tokyo',
    'Sydney' => 'Australia/Sydney',
    'Auckland' => 'Pacific/Auckland'
  }.freeze

  # --- Cap Bounds ---
  # A NULL cap means "no cap". A cap that is set is a dollar amount per
  # multiplier unit, so the bounds are only there to reject values that are
  # not real money.
  #
  # MIN_CAP: one cent is the smallest amount of money that exists. A cap of
  # $0.01 is silly but coherent; anything below it cannot be charged to
  # anyone. Zero and negative numbers also violate the database check
  # constraint communities_cap_positive_or_null, which raised a 500 instead
  # of showing the admin a form error.
  #
  # MAX_CAP: the column is DECIMAL(12, 8), which leaves four digits before the
  # decimal point, so $9,999.99 is the largest whole-cent amount it can hold.
  # Anything larger raised PG::NumericValueOutOfRange. This is a storage limit,
  # not a judgment about what a meal should cost — no cap will ever come near
  # it. It is written in whole cents rather than as the column's true maximum
  # (9999.99999999) for two reasons. An admin who hits it reads a real amount
  # of money instead of a database column definition. And a whole-cent ceiling
  # cannot be rounded past: 9999.999999996 is under $10,000, but the column
  # rounds it to 10000.00000000 and overflows.
  MIN_CAP = BigDecimal('0.01')
  MAX_CAP = BigDecimal('9999.99')

  # --- Singleton Record ---
  # The communities table has at most one row, enforced by a unique index on
  # singleton_guard (which is always 0). Fresh deployments start with zero
  # rows; the operator creates the singleton via ActiveAdmin (see
  # app/admin/community.rb). This class method is the canonical way to access
  # the record post-setup and raises if it's called before bootstrap completes.
  def self.instance
    Current.community ||= first ||
                          raise('No Community record exists. Create one at /communities/new on the admin subdomain.')
  end

  validate :enforce_singleton, on: :create
  before_destroy { throw :abort }

  # When the singleton is first created, link any orphan admin users (those
  # created in `rails c` during bootstrap before a community existed) to this
  # community. Post-bootstrap the ActiveAdmin form always sets community_id
  # explicitly, so this hook is effectively a one-time bootstrap step.
  after_create :backfill_orphan_admin_users

  def backfill_orphan_admin_users
    AdminUser.where(community_id: nil).update_all(community_id: id)
  end

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id cap name singleton_guard timezone created_at updated_at
       schedule meals_per_rotation]
  end

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :timezone, inclusion: { in: SUPPORTED_TIMEZONES.values }
  validates :cap,
            numericality: {
              greater_than_or_equal_to: MIN_CAP,
              message: 'must be at least $0.01, or blank for no cap'
            },
            allow_nil: true
  validates :cap,
            numericality: {
              less_than_or_equal_to: MAX_CAP,
              message: 'must be $9,999.99 or less'
            },
            allow_nil: true
  # A cap is a dollar amount a person types, so it is whole cents — the same
  # rule Bill#amount enforces. Sub-cent math would still settle correctly,
  # but a sub-cent cap can only be a typo, and typos in money fields are
  # refused, not stored. Mirrored by the communities_cap_whole_cents CHECK
  # constraint for writes that skip the model.
  validate :cap_in_whole_cents

  # --- Meal schedule ---
  # A repeating cycle of 1..6 weeks; each week an array of days (0 = Sunday).
  # An empty week means "no meals that week"; the cycle as a whole must have
  # at least one day or the generator would never find a meal date. Which
  # calendar week is week 1 is fixed by MealSchedule::EPOCH, not stored per
  # community. Both rules mirror database CHECK constraints (migration
  # 20260807140000) so raw writes are caught too. See MealSchedule.
  validates :meals_per_rotation,
            numericality: {
              only_integer: true,
              in: 1..MealSchedule::MAX_MEALS_PER_ROTATION,
              message: 'must be a whole number from 1 to 100'
            }
  validate :schedule_shape

  # The admin form posts the checkbox grid as a hash of week rows, e.g.
  # {"0" => ["", "0", "1"], "1" => [""]} (the "" comes from a hidden field
  # that keeps a fully-unchecked week present). Normalize any input shape to
  # sorted integer arrays here, in the writer, so the form, the preview
  # endpoint, and the console all go through the same door. Values that
  # cannot be whole numbers stay as nil for the validation to report,
  # instead of raising mid-assignment.
  def schedule=(value)
    weeks = value.is_a?(Hash) ? value.keys.sort_by(&:to_i).map { |key| value[key] } : value
    weeks = weeks.map { |week| week.is_a?(Array) ? normalize_schedule_week(week) : week } if weeks.is_a?(Array)
    super(weeks)
  end

  def meal_schedule
    MealSchedule.new(weeks: schedule)
  end

  has_many :bills, dependent: :destroy
  has_many :meals, dependent: :destroy
  has_many :meal_residents, dependent: :destroy
  has_many :reconciliations, dependent: :destroy
  has_many :residents, dependent: :destroy
  has_many :guests, through: :residents, dependent: :destroy
  has_many :units, dependent: :destroy
  has_many :admin_users, dependent: :destroy
  has_many :rotations, dependent: :destroy
  has_many :events, dependent: :destroy
  has_many :guest_room_reservations, dependent: :destroy
  has_many :common_house_reservations, dependent: :destroy

  accepts_nested_attributes_for :admin_users

  # NULL cap means "no cap"
  def cap
    read_attribute(:cap)
  end

  def capped?
    cap.present?
  end

  # Report Methods

  # Dashboard "Cost per adult". Reads MealLedger's per-meal summaries,
  # so it cannot drift from settlement math: meals nobody attended are
  # skipped by the scope, capped meals count their effective cost, and a
  # zero-multiplier meal charges nobody (its effective cost is zero).
  # An adult is 2 multiplier units, hence the 2x.
  def unreconciled_ave_cost
    unreconciled = meals.unreconciled.with_attendees.preload(:meal_residents, :guests, :bills).to_a
    total_multiplier = unreconciled.sum(&:multiplier)
    return '--' if total_multiplier.zero?

    ledger = MealLedger.new(unreconciled)
    total_cost = unreconciled.sum(BigDecimal('0')) do |meal|
      ledger.summary_for(meal).effective_cost
    end
    val = 2 * (total_cost / total_multiplier)
    "$#{format('%0.02f', val)}/adult"
  end

  def unreconciled_ave_number_of_attendees
    unreconciled = meals.unreconciled
    meal_count = unreconciled.count
    return '--' if meal_count.zero?

    mr_count = MealResident.where(meal_id: unreconciled.select(:id)).count
    g_count = Guest.where(meal_id: unreconciled.select(:id)).count
    ((mr_count + g_count).to_f / meal_count).round(1)
  end

  def auto_rotation_length
    residents.where('multiplier >= 2').where(can_cook: true).size / 2
  end

  def auto_create_rotations
    unassigned = meals.where(rotation_id: nil).order(:date)
    rotation = nil
    unassigned.find_each do |meal|
      if rotation.nil?
        rotation = rotations.create!(description: "#{meal.date} to #{meal.date}",
                                     no_email: true)
      end
      meal.update!(rotation_id: rotation.id)
      first_date = rotation.meals.order(:date).first.date
      last_date = rotation.meals.order(:date).last.date
      rotation.update!(description: "#{first_date} to #{last_date}")
      rotation = nil if rotation.meals.count == auto_rotation_length
    end
  end

  # Create the next rotation: the next meals_per_rotation dates the schedule
  # produces, starting the day after the last existing meal (or today).
  # Which dates those are is entirely MealSchedule's answer — its fixed epoch
  # makes the cycle phase arithmetic, so nothing here needs to look at past
  # meals to know which week of the cycle comes next.
  def create_next_rotation
    if meals.where(rotation_id: nil).any?
      raise "Currently #{meals.where(rotation_id: nil).count} Meals not assigned to Rotations"
    end

    day_after_last_meal = meals.order(:date).last&.date&.tomorrow
    start = [Time.zone.today, day_after_last_meal].compact.max
    dates = meal_schedule.upcoming_dates(from: start, count: meals_per_rotation)

    rotations.create!(meals_attributes: dates.map { |date| { date: date, community_id: id } })
  end

  # Cache key for a specific calendar month. Same format as the Pusher channel
  # name in data_store.js — one key serves both cache and real-time notification.
  # Stale cache across deploys is handled by bin/deploy clearing the cache.
  def calendar_cache_key(year, month)
    "community-#{id}-calendar-#{year}-#{month}"
  end

  # Invalidate calendar cache entries that may include meals on this date.
  # Must be called synchronously (before the response) so the next request
  # doesn't get stale data. See CalendarSerializer for the full list of models
  # that must call this when their data changes.
  def invalidate_calendar_cache(date)
    affected_calendar_keys(date).each { |key| Rails.cache.delete(key) }
  end

  # Send Pusher notifications for calendar channels affected by this date.
  # Fire-and-forget — safe to call asynchronously.
  def notify_pusher(date)
    affected_calendar_keys(date).each do |key|
      Pusher.trigger(key, 'update', { message: 'calendar updated' })
    end
  end

  # Invalidate calendar cache and send Pusher notifications for the
  # affected month(s). Called by Meal#trigger_pusher and by calendar-visible
  # models (Event, CommonHouseReservation, GuestRoomReservation) via
  # after_commit. See CalendarSerializer for the full invalidation contract.
  def trigger_pusher(date)
    invalidate_calendar_cache(date)
    notify_pusher(date)
    true
  end

  private

  def enforce_singleton
    errors.add(:base, 'Only one Community record is allowed') if Community.exists?
  end

  def normalize_schedule_week(week)
    days = week.reject { |day| day.to_s.strip.empty? }
               .map { |day| day.is_a?(Integer) ? day : Integer(day.to_s, exception: false) }
               .uniq
    days.all?(Integer) ? days.sort : days
  end

  def cap_in_whole_cents
    return if cap.nil? || cap == cap.round(2)

    errors.add(:cap, 'must be whole cents')
  end

  def schedule_shape
    unless schedule.is_a?(Array) && schedule.length.between?(1, MealSchedule::MAX_WEEKS)
      errors.add(:schedule, "must have between 1 and #{MealSchedule::MAX_WEEKS} weeks")
      return
    end
    unless schedule.all? { |week| week.is_a?(Array) && week.all? { |day| day.is_a?(Integer) && day.between?(0, 6) } }
      errors.add(:schedule, 'days must be 0 (Sunday) through 6 (Saturday)')
      return
    end
    errors.add(:schedule, 'must include at least one meal day') if schedule.flatten.empty?
  end

  # The set of calendar keys affected when a meal on `date` changes.
  # A calendar view shows ~42 days (6 weeks), so a meal near a month boundary
  # can appear in the current, next, or previous month's calendar.
  def affected_calendar_keys(date)
    keys = []

    # Current month
    keys << calendar_cache_key(date.year, date.month)

    # Next month — if the date's week spills into the following month
    keys << calendar_cache_key(date.end_of_week.year, date.end_of_week.month) if date.end_of_week.month != date.month

    # Previous month — if the date falls within the previous month's 42-day window
    range_start = (date.beginning_of_month - 1.day).beginning_of_month.beginning_of_week(:sunday)
    if date.between?(range_start, range_start + 41.days)
      prev_month = date.beginning_of_month - 1.day
      keys << calendar_cache_key(prev_month.year, prev_month.month)
    end

    keys
  end
end

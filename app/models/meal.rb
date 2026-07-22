# frozen_string_literal: true

# == Schema Information
#
# Table name: meals
#
#  id                :bigint           not null, primary key
#  cap               :decimal(12, 8)
#  closed            :boolean          default(FALSE), not null
#  closed_at         :datetime
#  date              :date             not null
#  description       :text             default(""), not null
#  max               :integer
#  start_time        :datetime         not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  community_id      :bigint           not null
#  reconciliation_id :bigint
#  rotation_id       :bigint
#
# Indexes
#
#  index_meals_on_date               (date) UNIQUE
#  index_meals_on_reconciliation_id  (reconciliation_id)
#  index_meals_on_rotation_id        (rotation_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (rotation_id => rotations.id)
#
class Meal < ApplicationRecord
  # Ransack allowlists for ActiveAdmin filtering and sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id cap closed closed_at community_id created_at date description max reconciliation_id rotation_id start_time
       updated_at]
  end

  ALTERNATING_DAYS = [1, 2].freeze
  TEMPLATE_WDAYS = [0, 4].freeze

  # Attributes frozen once the meal is reconciled. Bills and attendance rows
  # carry their own reconciled guards; this protects the meal row itself.
  # cap feeds max_cost, so editing it would rewrite settled charges; date
  # fixes which settlement period the meal belongs to; reconciliation_id is
  # the pointer to the settlement itself (no re-pointing, no un-reconciling).
  # community_id is deliberately absent: Community is a DB-enforced singleton
  # (unique singleton_guard), so there is no other community to move to and
  # belongs_to already rejects nonexistent ids before before_save runs.
  FROZEN_WHEN_RECONCILED = %w[cap date reconciliation_id].freeze

  audited
  has_associated_audits

  attr_accessor :socket_id

  scope :unreconciled, -> { where(reconciliation_id: nil) }
  scope :open, -> { where(closed: false) }
  scope :closed_with_bills, -> { where(closed: true).joins(:bills).distinct }

  # Meals where at least one person ate (meal_resident or guest).
  # A bill on a meal with no attendees has zero financial impact —
  # the cook absorbs the cost and is not reimbursed.
  # Uses EXISTS (not JOIN) to avoid multiplying rows in SUM queries.
  scope :with_attendees, lambda {
    mr = MealResident.arel_table
    g = Guest.arel_table
    where(
      MealResident.where(mr[:meal_id].eq(arel_table[:id])).arel.exists
        .or(Guest.where(g[:meal_id].eq(arel_table[:id])).arel.exists)
    )
  }

  belongs_to :community
  belongs_to :reconciliation, optional: true
  belongs_to :rotation, optional: true

  has_many :bills, inverse_of: :meal, dependent: :destroy
  has_many :cooks, through: :bills, source: :resident, dependent: :destroy
  has_many :meal_residents, inverse_of: :meal, dependent: :destroy
  has_many :guests, inverse_of: :meal, dependent: :destroy
  has_many :hosts, through: :guests, source: :resident, dependent: :destroy
  has_many :attendees, through: :meal_residents, source: :resident, dependent: :destroy
  has_many :residents, -> { where active: true }, through: :community

  before_validation :set_start_time, on: :create

  validates :date, presence: true
  validates :max,
            numericality: {
              greater_than_or_equal_to: :attendees_count,
              message: "Max can't be less than current number of attendees."
            },
            allow_nil: true

  validates :date, uniqueness: true

  # Reconciled meals are immutable (accounting principle: no edits to a closed
  # ledger). Settlement inputs are frozen; an unreconciled meal can still be
  # reconciled (reconciliation_id nil -> id happens via update_all anyway).
  before_save :reject_frozen_changes_if_reconciled
  before_save :conditionally_set_max
  before_save :conditionally_set_closed_at
  before_create :set_cap
  before_destroy :reject_destroy_if_reconciled

  accepts_nested_attributes_for :guests, allow_destroy: true, reject_if: proc { |attributes|
    attributes['resident_id'].blank?
  }
  accepts_nested_attributes_for :bills, allow_destroy: true, reject_if: proc { |attributes|
    attributes['resident_id'].blank?
  }

  def get_start_time # rubocop:disable Naming/AccessorMethodName -- frontend API expects get_start_time
    start_time.in_time_zone(community.timezone)
  end

  # NULL cap means "no cap". No more Float::INFINITY.
  def cap
    read_attribute(:cap)
  end

  def capped?
    cap.present?
  end

  def set_cap
    self.cap = community.cap
  end

  def set_start_time
    self.start_time = date.wday.zero? ? date.to_datetime + 18.hours : date.to_datetime + 19.hours
  end

  def conditionally_set_max
    self.max = nil if closed == false
  end

  def conditionally_set_closed_at
    self.closed_at = DateTime.now if closed == true && closed_was == false
    self.closed_at = nil if closed == false && closed_was == true
  end

  # Invalidate caches and notify connected clients via Pusher.
  # Called by MealsController after_action for all write operations.
  # Also handles calendar cache invalidation for meals, bills, meal_residents,
  # and guests. See CalendarSerializer for the full cache invalidation contract.
  def trigger_pusher
    key = "meal-#{id}"

    Rails.cache.delete(key)

    Pusher.trigger(
      key,
      'update',
      { message: 'meal updated' },
      { socket_id: socket_id }
    )

    community.trigger_pusher(date)

    true
  end

  # DERIVED DATA — all computed from source, no cached columns.

  def multiplier
    if meal_residents.loaded? && guests.loaded?
      meal_residents.sum(&:multiplier) + guests.sum(&:multiplier)
    else
      meal_residents.sum(:multiplier) + guests.sum(:multiplier)
    end
  end

  def attendees_count
    if meal_residents.loaded? && guests.loaded?
      meal_residents.size + guests.size
    else
      meal_residents.count + guests.count
    end
  end

  delegate :count, to: :bills, prefix: true

  # Total cost computed from source bills. Sums in memory when the caller
  # preloaded bills (same contract as multiplier above — this is what lets
  # the dashboard render many meals without one query per meal), otherwise
  # one cheap indexed SQL SUM. No memoization — bills can change within a
  # request, and stale data in financial calculations is worse than
  # recomputing.
  def total_cost
    if bills.loaded?
      bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
    else
      bills.where(no_cost: false).sum(:amount)
    end
  end

  # The cost used for splitting after applying the cap.
  # If uncapped or under cap, this equals total_cost.
  # If over cap, this equals max_cost.
  def effective_total_cost
    tc = total_cost
    return tc unless capped?

    mc = max_cost
    [tc, mc].min
  end

  # Per-multiplier-unit cost. Single division, no per-bill iteration.
  def unit_cost
    return BigDecimal('0') if multiplier.zero?

    effective_total_cost / multiplier
  end

  # Maximum total cost for this meal based on the community cap.
  # Returns nil if uncapped.
  def max_cost
    return nil unless capped?

    cap * multiplier
  end

  def subsidized?
    return false if multiplier.zero?
    return false unless capped?

    total_cost > max_cost
  end

  def reconciled?
    reconciliation_id.present?
  end

  # Guards the meal row itself once settled. Checks the DATABASE value of
  # reconciliation_id, not the in-memory one, so reconciling an unreconciled
  # meal (nil -> id) stays legal at the model layer.
  def reject_frozen_changes_if_reconciled
    return if reconciliation_id_in_database.nil?

    frozen = changes_to_save.keys & FROZEN_WHEN_RECONCILED
    return if frozen.empty?

    errors.add(:base, "Meal has been reconciled. #{frozen.to_sentence} cannot change.")
    throw(:abort)
  end

  # Destroying a settled meal would erase settled source data (and cascade
  # into its bills and attendance rows). Corrections happen as new entries.
  def reject_destroy_if_reconciled
    return unless reconciled?

    errors.add(:base, 'Meal has been reconciled.')
    throw(:abort)
  end

  def total_audits
    (associated_audits + audits).sort { |a, b| b.created_at <=> a.created_at }
  end

  # HELPERS
  def another_meal_in_this_rotation_has_less_than_two_cooks?
    return false if rotation_id.nil?

    Meal.where(rotation_id: rotation_id).where.not(id: id)
        .left_joins(:bills)
        .group(:id)
        .having('COUNT(bills.id) < 2')
        .exists?
  end

  # *** This method only used during seed generation ***
  # Typical 3x a week schedule with alternating Mon / Tues
  def self.create_templates(start_date, end_date, alternating_dinner_day)
    community = Community.instance
    count = 0
    dates = (start_date..end_date).to_a

    dates.each do |date|
      # Skip holidays
      next if Meal.is_holiday?(date)

      # Skip days without dinner
      next unless [0, alternating_dinner_day, 4].any?(date.wday)

      # Flip the alternating dinner day
      if date.wday == alternating_dinner_day
        alternating_dinner_day = ALTERNATING_DAYS.find do |val|
          val != alternating_dinner_day
        end
      end

      # Create the meal
      meal = Meal.new(date: date, community: community)
      if meal.save
        count += 1
      else
        Rails.logger.debug meal.errors
      end
    end

    count
  end

  # *** This method only used during seed generation ***
  # Modified twice a week schedule
  def self.create_modified_templates(start_date, end_date)
    community = Community.instance
    count = 0
    dates = (start_date..end_date).to_a

    dates.each do |date|
      # Skip holidays
      next if Meal.is_holiday?(date)

      # Skip days without dinner
      next unless TEMPLATE_WDAYS.any?(date.wday)

      # Create the meal
      meal = Meal.new(date: date, community: community)
      if meal.save
        count += 1
      else
        Rails.logger.debug meal.errors
      end
    end

    count
  end

  def self.is_holiday?(date)
    return true if  Meal.is_thanksgiving(date)  ||
                    Meal.is_christmas(date)     ||
                    Meal.is_newyears(date)      ||
                    Meal.is_mothers_day(date)   ||
                    Meal.is_easter(date)        ||
                    Meal.is_july_fourth(date)

    false
  end

  def self.is_thanksgiving(date)
    return false unless date.instance_of?(Date)
    return false unless date.month == 11
    return false unless date.thursday?
    return false unless date.day.between?(22, 28)

    true
  end

  def self.is_christmas(date)
    return true if date.month == 12 && date.day == 25

    false
  end

  def self.is_newyears(date)
    return true if date.month == 1 && date.day == 1

    false
  end

  def self.is_mothers_day(date)
    return false unless date.instance_of?(Date)
    return false unless date.month == 5
    return false unless date.sunday?
    return false unless date.day.between?(8, 14)

    true
  end

  def self.is_easter(date) # rubocop:disable Metrics/AbcSize -- Anonymous Gregorian algorithm, inherently arithmetic-heavy
    y = date.year
    a = y % 19
    b = y / 100
    c = y % 100
    d = b / 4
    e = b % 4
    f = (b + 8) / 25
    g = (b - f + 1) / 3
    h = ((19 * a) + b - d - g + 15) % 30
    i = c / 4
    k = c % 4
    l = (32 + (2 * e) + (2 * i) - h - k) % 7
    m = (a + (11 * h) + (22 * l)) / 451

    month = (h + l - (7 * m) + 114) / 31
    day = ((h + l - (7 * m) + 114) % 31) + 1

    return true if date.month == month && date.day == day

    false
  end

  def self.is_july_fourth(date)
    return true if date.month == 7 && date.day == 4

    false
  end
end

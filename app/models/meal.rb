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
  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin filtering and sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id cap closed closed_at created_at date description max reconciliation_id rotation_id start_time
       updated_at]
  end

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
  # The meals a settlement with this cutoff sweeps: not yet settled, with at
  # least one bill, on or before the cutoff, and from a day that is over.
  # Meals on today's date are never swept, whatever the cutoff — their
  # receipts and attendance are not final (issue #3).
  scope :settleable_by, lambda { |cutoff, today: Community.instance.today|
    unreconciled.joins(:bills).where(date: ..cutoff).where(date: ...today).distinct
  }
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

  belongs_to :reconciliation, optional: true
  belongs_to :rotation, optional: true

  # Settlement line items exist only on reconciled meals, which already refuse
  # destroy (the prepended guard below). restrict_with_error is the readable
  # backstop for the same rule, declared before the destroy cascades so the
  # check runs before anything is deleted.
  has_many :meal_charges, dependent: :restrict_with_error

  has_many :bills, inverse_of: :meal, dependent: :destroy
  has_many :cooks, through: :bills, source: :resident, dependent: :destroy
  has_many :meal_residents, inverse_of: :meal, dependent: :destroy
  has_many :guests, inverse_of: :meal, dependent: :destroy
  has_many :hosts, through: :guests, source: :resident, dependent: :destroy
  has_many :attendees, through: :meal_residents, source: :resident, dependent: :destroy

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
  # Both destroy guards are prepended: the has_many declarations above
  # register their dependent cascades first, so without prepend a destroy
  # attempt deletes the meal's bills before the guard aborts. In a request
  # that partial delete rolls back, but inside an enclosing transaction
  # (console, rake task, test transaction) the swallowed inner rollback
  # never reaches the outer transaction and the bills stay deleted.
  # Reconciled is declared second so it runs first — its message wins for
  # meals that are both reconciled and closed.
  before_destroy :reject_destroy_if_closed, prepend: true
  before_destroy :reject_destroy_if_reconciled, prepend: true

  accepts_nested_attributes_for :guests, allow_destroy: true, reject_if: proc { |attributes|
    attributes['resident_id'].blank?
  }
  accepts_nested_attributes_for :bills, allow_destroy: true, reject_if: proc { |attributes|
    attributes['resident_id'].blank?
  }

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

  # Notify connected clients via Pusher, and clear the calendar cache for
  # this meal's month. Called by MealsController after_action for all write
  # operations, so it also covers bills, meal_residents, and guests. See
  # CalendarSerializer for the full cache invalidation contract.
  #
  # meal-<id> is only a Pusher channel now. The cooks page is not cached
  # (MealsController#show_cooks explains why), so there is no entry to
  # delete here.
  def trigger_pusher
    key = "meal-#{id}"

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

  # No cost methods here on purpose. What a meal costs is MealLedger's
  # arithmetic; screens read it (or the stored meal_charges of a settled
  # meal) through MealCostSummary. A convenience copy on this model is
  # how the math ended up living in three places (#48).

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

  # A closed meal's attendance is frozen (ClosedMealAttendanceFreeze), so its
  # destroy could never complete anyway — the cascade would abort on the
  # first frozen row. Refuse up front with a clear reason instead. To delete
  # a closed meal that never happened, reopen it first — two deliberate steps.
  def reject_destroy_if_closed
    return unless closed?

    errors.add(:base, 'Meal has been closed. Reopen it before deleting.')
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

  def self.is_holiday?(date)
    Meal.is_thanksgiving(date)  ||
      Meal.is_christmas(date)   ||
      Meal.is_newyears(date)    ||
      Meal.is_mothers_day(date) ||
      Meal.is_easter(date)      ||
      Meal.is_july_fourth(date)
  end

  def self.is_thanksgiving(date)
    return false unless date.instance_of?(Date)
    return false unless date.month == 11
    return false unless date.thursday?
    return false unless date.day.between?(22, 28)

    true
  end

  def self.is_christmas(date)
    date.month == 12 && date.day == 25
  end

  def self.is_newyears(date)
    date.month == 1 && date.day == 1
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

    date.month == month && date.day == day
  end

  def self.is_july_fourth(date)
    date.month == 7 && date.day == 4
  end
end

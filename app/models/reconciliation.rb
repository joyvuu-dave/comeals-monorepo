# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliations
#
#  id           :bigint           not null, primary key
#  date         :date             not null
#  end_date     :date             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
class Reconciliation < ApplicationRecord
  extend T::Sig

  include BelongsToTheCommunity

  # Raised when something tries to create a row without going through
  # Settlement. See refuse_create_outside_settlement.
  class NotSettled < StandardError; end

  # Raw balances are computed with BigDecimal division carrying ~20+
  # significant digits, so a balanced input sums to within ~1e-15 of zero even
  # across thousands of meals. Any genuine upstream imbalance manifests at a
  # fraction of a cent or more — orders of magnitude above this epsilon.
  ZERO_SUM_EPSILON = T.let(BigDecimal('0.000001'), BigDecimal)

  # Ransack allowlists for ActiveAdmin sorting
  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_attributes(_auth_object = nil)
    %w[id date end_date created_at updated_at]
  end

  has_many :meals, dependent: :nullify
  has_many :bills, through: :meals
  has_many :cooks, through: :bills, source: :resident
  has_many :reconciliation_balances, dependent: :destroy

  audited

  validates :end_date, presence: true
  validate :end_date_before_today
  validate :must_settle_at_least_one_meal, on: :create

  before_validation :set_date
  before_create :refuse_create_outside_settlement
  # Reconciliations are append-only settlement events: once created (and cooks
  # notified of their amounts), the row must never change or disappear through
  # normal application paths. end_date is the invariant defining which meals
  # were swept — editing it after the fact would make the stored cutoff
  # contradict the meals actually settled. Corrections settle as new entries
  # in the next reconciliation. If un-settlement is ever required, write a
  # deliberate rake task that uses `delete` / `update_columns` to bypass
  # these guards.
  #
  # The destroy guard aborts before the has_many dependent callbacks
  # declared above (nullify meals, destroy balances) can un-reconcile
  # anything — see AppendOnly for the prepend reasoning (issue #26).
  include AppendOnly

  append_only update_message: 'Reconciliations are settlement events and cannot be modified. ' \
                              'Corrections settle as new entries in the next reconciliation.',
              destroy_message: 'Reconciliations are settlement events and cannot be destroyed.'

  sig { returns(Integer) }
  def number_of_meals
    meals.count
  end

  sig { returns(T::Array[Resident]) }
  def unique_cooks
    cooks.uniq
  end

  # The period this settlement covers: the dates of the meals it swept.
  # Neither date column is the start of that period — `date` is the day the
  # settlement ran and `end_date` is the sweep cutoff — so a "date to
  # end_date" display reads backwards ("2026-08-10 to 2026-06-15").
  sig { returns(String) }
  def date_range_description
    DateRangeDescription.for(meals.minimum(:date), meals.maximum(:date))
  end

  # Compute final settlement balances for this reconciliation period.
  # Returns a hash of { resident_id => rounded_balance }.
  # Uses largest-remainder method (Hamilton's method) to round to cents,
  # guaranteeing the total sums to exactly zero.
  #
  # The arithmetic itself is MealLedger's, which the running-balance rake task
  # also uses. This method is only the settlement-specific part: which meals,
  # which residents, and the rounding to cents.
  #
  # Memory: loads all reconciled meals + associations into RAM. For a co-housing
  # community (~500 meals max), this is ~18K AR objects (~36 MB). Bounded by the
  # physical size of the community.
  sig { params(ledger: MealLedger).returns(T::Hash[Integer, BigDecimal]) }
  def settlement_balances(ledger = settlement_ledger)
    raw_balances = ledger.balances(T.must(community).residents.pluck(:id))

    # Round to cents using largest-remainder method (Hamilton's method).
    # This guarantees rounded balances sum to exactly zero — the standard
    # accounting approach for apportioning monetary amounts. Each value is
    # within 1 cent of its exact full-precision amount.
    balances = Settlement.allocate_to_cents(raw_balances, reconciliation_id: id)

    # Verify the books balance exactly. allocate_to_cents guarantees this;
    # a non-zero sum indicates a bug in the allocation algorithm.
    total = balances.values.sum(BigDecimal('0'))
    unless total.zero?
      raise "settlement_balances: books do not balance for reconciliation #{id}. " \
            "Discrepancy: #{total}. This indicates a bug in Settlement.allocate_to_cents."
    end

    balances
  end

  # The meals this reconciliation settled, loaded once with everything the
  # arithmetic needs.
  #
  # Uses preload (not includes) to guarantee separate IN(?) queries — includes
  # can silently switch to LEFT JOIN if a .where is later chained on an
  # included table, which would produce a cartesian product across 3
  # associations. MealLedger runs no queries of its own, so these three
  # associations must be loaded before it sees the meals.
  sig { returns(MealLedger) }
  def settlement_ledger
    MealLedger.new(meals.with_attendees.preload(:bills, :meal_residents, :guests).to_a)
  end

  # Settlement balances grouped by unit. Returns { [unit_id, unit_name] => BigDecimal }
  # for every community unit, including units whose residents all have $0.00 balances.
  UnitKey = T.type_alias { [Integer, String] }

  sig { returns(T::Hash[UnitKey, BigDecimal]) }
  def unit_balances
    # Grouped sum: Sorbet's relation sigs only know the ungrouped, scalar form.
    grouped = T.cast(reconciliation_balances
                       .joins(resident: :unit)
                       .group('units.id', 'units.name')
                       .sum(:amount), T::Hash[UnitKey, BigDecimal])

    result = T.let({}, T::Hash[UnitKey, BigDecimal])
    T.must(community).units.order(:name).each do |unit|
      key = [T.must(unit.id), T.must(unit.name)]
      result[key] = grouped.fetch(key, BigDecimal('0'))
    end
    result
  end

  # The meals this reconciliation would sweep. The create validation and
  # Settlement#assign_meals both read this one scope, so they cannot disagree
  # about what "eligible" means. A second copy of the predicate could drift,
  # and then a reconciliation would pass validation and go on to claim zero
  # meals.
  sig { returns(ActiveRecord::Relation) }
  def eligible_meals
    Meal.settleable_by(end_date, today: T.must(community).today)
  end

  # Settlement calls this before saving the row it is about to settle. See
  # refuse_create_outside_settlement.
  sig { void }
  def mark_settling!
    @settling = T.let(true, T.nilable(T::Boolean))
  end

  private

  sig { void }
  def set_date
    self.date ||= T.must(community).today
  end

  # A reconciliation may only settle days that are over. Meals on today's date
  # (or later) may not have happened yet — cooks' receipts and attendance are
  # not final — so the cutoff must be strictly in the past (issue #3).
  sig { void }
  def end_date_before_today
    end_date = self.end_date
    return if end_date.nil?
    return if end_date < T.must(community).today

    errors.add(:end_date, 'must be in the past')
  end

  # A reconciliation is a settlement event. One that settles nothing is a
  # data-entry mistake, and the table is append-only, so there is no way to
  # remove it afterwards: it stays in the admin list and in every resident's
  # history as a settlement that settled no meals, and it becomes
  # `Reconciliation.last`, which is the row `reconciliations:send_cooking_slot_email`
  # emails cooks about. The nightly `reconciliations:create` task already
  # refuses this case and logs a skip; this validation closes the same hole on
  # the ActiveAdmin form, which is the only other way to create one.
  #
  # This reads the same eligible_meals scope that assign_meals sweeps, so the
  # two cannot disagree about which meals count.
  sig { void }
  def must_settle_at_least_one_meal
    return if end_date.blank?
    return if errors[:end_date].any?
    return if eligible_meals.exists?

    errors.add(:base, 'No unreconciled meals with bills on or before this date. ' \
                      'A reconciliation must settle at least one meal.')
  end

  # A reconciliation row is only ever written by Settlement, in the same
  # transaction that claims the meals and writes the ledger. A row created
  # any other way would be a settlement that settled nothing, and the table
  # is append-only, so it could never be cleaned up.
  sig { void }
  def refuse_create_outside_settlement
    return if @settling

    raise NotSettled,
          'Reconciliation rows are written by Settlement.run!(cutoff:), which settles the period ' \
          'in the same transaction. Reconciliation.create! alone would leave a settlement that ' \
          'settled nothing.'
  end
end

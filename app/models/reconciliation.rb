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

  # A settlement covers only dinners at least this many days old, so a
  # cook has time to fix a cost before the dinner is locked for good (ADR
  # 0011 rule 2). Of the 64 cook costs entered from January to mid-August
  # 2026, 9 were changed more than 1 day after the dinner, 2 more than 7
  # days after, and 1 more than 14 days after (on day 15).
  DAYS_TO_WAIT = 14

  # The latest cutoff a settlement made on this day may have.
  sig { params(today: Date).returns(Date) }
  def self.latest_cutoff(today) = today - DAYS_TO_WAIT

  # Why a settlement made on this day may not have this cutoff, or nil
  # when it may. The model validation and Settlement.preview both read
  # it, so the form, the API and the rake task give the same words.
  sig { params(cutoff: Date, today: Date).returns(T.nilable(String)) }
  def self.cutoff_refusal(cutoff, today)
    latest = latest_cutoff(today)
    return if cutoff <= latest

    "must be on or before #{latest.iso8601}, #{DAYS_TO_WAIT} days before today"
  end

  # Ransack allowlists for ActiveAdmin sorting
  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_attributes(_auth_object = nil)
    %w[id date end_date created_at updated_at]
  end

  has_many :meals, dependent: :nullify
  has_many :bills, through: :meals
  has_many :reconciliation_balances, dependent: :destroy
  # Each time this settlement's numbers were worked out again after it was
  # made (Settlement#correct!), oldest first.
  has_many :settlement_corrections, -> { order(:created_at, :id) }, dependent: :restrict_with_exception,
                                                                    inverse_of: :reconciliation
  # The corrections to earlier settlements' dinners that this settlement
  # carries (ADR 0011 rule 6), oldest first.
  has_many :meal_corrections, -> { order(:id) }, dependent: :restrict_with_exception, inverse_of: :reconciliation

  audited

  validates :end_date, presence: true
  validate :end_date_old_enough, on: :create
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
  # these guards. When the owner decides a settlement's numbers must be
  # worked out again after its rows were fixed, Settlement#correct! does
  # it: the row, its meals and its cutoff stay; its balances and line
  # items are replaced; a SettlementCorrection records what changed.
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

  # The people who cooked a dinner in these settlements (a relation), as
  # each settlement settled it: rows of (reconciliation_id, resident_id).
  #
  # A dinner's bills now are not always the ones its settlement settled.
  # A correction adds, removes or changes a cook's bill later (ADR 0011
  # rule 6), and its record keeps each cook's cost before the change
  # (MealCorrecting::Edits). So a cook no correction names on a dinner is
  # one its bills show. For a cook a correction does name, the first such
  # edit says whether they cooked when the dinner settled: their cost
  # before it is an object if they did, and null if they were not a cook.
  sig { params(reconciliations: ActiveRecord::Relation).returns(Arel::Nodes::Union) }
  def self.settled_cooks(reconciliations)
    named = MealCorrection.cost_edits.where('meal_corrections.meal_id = bills.meal_id')
                          .where(MealCorrection::COOK_ID.eq(Bill.arel_table[:resident_id]))
    unnamed = Bill.joins(:meal).where(meals: { reconciliation_id: reconciliations.select(:id) })
                  .where(named.arel.exists.not)
                  .select('meals.reconciliation_id', 'bills.resident_id')
    first_edits = MealCorrection
                  .cost_edits.joins(:meal).where(meals: { reconciliation_id: reconciliations.select(:id) })
                  .select(Arel.sql('DISTINCT ON (meal_corrections.meal_id, cook_id) meals.reconciliation_id'),
                          MealCorrection::COOK_ID.as('cook_id'), MealCorrection::COST_BEFORE.as('cost_before'))
                  .order(Arel.sql('meal_corrections.meal_id, cook_id, meal_corrections.id, cost_edit.place'))
    were_cooks = MealCorrection.from(first_edits, :first_edits)
                               .where("jsonb_typeof(first_edits.cost_before) = 'object'")
                               .select('first_edits.reconciliation_id', 'first_edits.cook_id')
    Arel::Nodes::Union.new(unnamed.arel, were_cooks.arel)
  end

  # Whether this resident cooked a dinner in this settlement, as it
  # settled it (settled_cooks).
  sig { params(resident: Resident).returns(T::Boolean) }
  def settled_cook?(resident)
    cooks = Arel::Nodes::TableAlias.new(self.class.settled_cooks(self.class.where(id: id)), 'settled_cooks')
    Resident.from(cooks).exists?(settled_cooks: { resident_id: resident.id })
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
  #
  # Corrections (ADR 0011 rule 6) change it two ways. This settlement
  # carries the corrections it claimed, so their lines are added. And a
  # correction made later to one of this settlement's meals changed that
  # meal's rows, which the ledger reads as they are now, so those lines
  # are taken off again: this settlement keeps what it settled. While the
  # settlement is being written, none of its meals has a correction yet
  # (a meal is corrected only once settled), so only the first applies.
  sig { params(ledger: MealLedger).returns(T::Hash[Integer, BigDecimal]) }
  def settlement_balances(ledger = settlement_ledger)
    raw_balances = ledger.balances(T.must(community).residents.pluck(:id))
    add_correction_lines!(raw_balances, MealCorrection.where(reconciliation_id: id))
    add_correction_lines!(raw_balances, MealCorrection.where(meal_id: meals.select(:id)), sign: -1)

    # Round to cents using largest-remainder method (Hamilton's method).
    # This guarantees rounded balances sum to exactly zero — the standard
    # accounting approach for apportioning monetary amounts. Each value is
    # less than 1 cent from its exact amount at the ledger grain.
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
  # The scope reads today from the one community itself, the same value
  # this row would pass it (mutant showed the argument changed nothing,
  # 2026-09-10).
  sig { returns(ActiveRecord::Relation) }
  def eligible_meals
    Meal.settleable_by(end_date)
  end

  # Settlement calls this before saving the row it is about to settle. See
  # refuse_create_outside_settlement.
  sig { void }
  def mark_settling!
    @settling = T.let(true, T.nilable(T::Boolean))
  end

  private

  # Each person's lines from these corrections, added to their raw
  # balance, or taken off it with sign -1.
  sig { params(raw: T::Hash[Integer, BigDecimal], corrections: ActiveRecord::Relation, sign: Integer).void }
  def add_correction_lines!(raw, corrections, sign: 1)
    lines = MealCorrectionLine.where(meal_correction_id: corrections.select(:id)).group(:resident_id).sum(:amount)
    T.cast(lines, T::Hash[Integer, BigDecimal]).each do |resident_id, amount|
      raw[resident_id] = raw.fetch(resident_id, BigDecimal('0')) + (sign * amount)
    end
  end

  sig { void }
  def set_date
    self.date ||= T.must(community).today
  end

  # The cutoff must be at least DAYS_TO_WAIT days before today, in the
  # community's time zone (ADR 0011 rule 2). This also keeps out today's
  # meal and later ones, which may not have happened yet (issue #3). On
  # create only: the rule is about making a settlement. A row that exists
  # stays valid, whatever its cutoff.
  sig { void }
  def end_date_old_enough
    end_date = self.end_date
    return if end_date.nil?

    refusal = Reconciliation.cutoff_refusal(end_date, T.must(community).today)
    errors.add(:end_date, refusal) if refusal
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
  # A blank end date is already an end_date error by the time this runs
  # (the presence validation is declared first), so that case needs no
  # guard of its own (mutant showed it dead, 2026-09-10).
  #
  # When the period has meals with bills but every one is held back (money
  # on a bill and nobody who pays signed up, Meal.receipt_and_nobody_to_charge)
  # or waits for a cook's cost (Meal.waiting_for_a_cost), "no meals with
  # bills" would be false, so the answer names those meals and says what
  # has to change before they can settle.
  #
  # A settlement with no meal is allowed when it carries a correction (ADR
  # 0011 rule 6): otherwise a correction made when there were no new
  # dinners would wait with no end.
  sig { void }
  def must_settle_at_least_one_meal
    return if errors[:end_date].any?
    return if eligible_meals.exists? || MealCorrection.waiting.exists?

    held = left_behind_dates(Meal.unreconciled.receipt_and_nobody_to_charge)
    waiting = left_behind_dates(Meal.unreconciled.waiting_for_a_cost)
    if held.empty? && waiting.empty?
      errors.add(:base, 'No unreconciled meals with bills on or before this date. ' \
                        'A reconciliation must settle at least one meal or carry a correction.')
    else
      errors.add(:base, ['No meal on or before this date can be settled yet.', held_words(held),
                         waiting_words(waiting),
                         'A reconciliation must settle at least one meal or carry a correction.'].compact.join(' '))
    end
  end

  sig { params(held: T::Array[Date]).returns(T.nilable(String)) }
  def held_words(held)
    return if held.empty?

    'Meals held back because a bill has money on it and nobody who pays is signed up: ' \
      "#{held.map(&:iso8601).to_sentence}. To settle one, sign up someone who pays or remove the bill."
  end

  sig { params(waiting: T::Array[Date]).returns(T.nilable(String)) }
  def waiting_words(waiting)
    return if waiting.empty?

    "Meals waiting for a cook's cost: #{waiting.map(&:iso8601).to_sentence}. " \
      'To settle one, each of its cooks enters a cost or marks No cost.'
  end

  # The dates of these unreconciled meals up to the cutoff, which a
  # settlement leaves behind, oldest first. Settlement.held_by and
  # waiting_by also leave out today and later, but this only runs once
  # end_date is old enough, so the cutoff already does that.
  sig { params(meals: ActiveRecord::Relation).returns(T::Array[Date]) }
  def left_behind_dates(meals)
    meals.where(date: ..end_date).order(:date).pluck(:date)
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

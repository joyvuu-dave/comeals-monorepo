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
  # Raw balances are computed with BigDecimal division carrying ~20+
  # significant digits, so a balanced input sums to within ~1e-15 of zero even
  # across thousands of meals. Any genuine upstream imbalance manifests at a
  # fraction of a cent or more — orders of magnitude above this epsilon.
  ZERO_SUM_EPSILON = BigDecimal('0.000001')

  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id community_id date end_date created_at updated_at]
  end

  has_many :meals, dependent: :nullify
  has_many :bills, through: :meals
  has_many :cooks, through: :bills, source: :resident
  has_many :reconciliation_balances, dependent: :destroy
  belongs_to :community

  audited

  validates :end_date, presence: true
  validate :end_date_before_today

  before_validation :set_date
  after_create :finalize
  # Reconciliations are append-only settlement events: once created (and cooks
  # notified of their amounts), the row must never change or disappear through
  # normal application paths. end_date is the invariant defining which meals
  # were swept — editing it after the fact would make the stored cutoff
  # contradict the meals actually settled. Corrections settle as new entries
  # in the next reconciliation. If un-settlement is ever required, write a
  # deliberate rake task that uses `delete` / `update_columns` to bypass
  # these guards.
  #
  # reject_destroy is prepended: the has_many declarations above register
  # their dependent callbacks (nullify meals, destroy balances) first, so
  # without prepend a destroy attempt would un-reconcile every meal before
  # the abort — a write the settled-meal DB triggers refuse (issue #26).
  # Prepending aborts the destroy before any association write is attempted.
  before_update :reject_update
  before_destroy :reject_destroy, prepend: true

  def reject_update
    errors.add(:base, 'Reconciliations are settlement events and cannot be modified. ' \
                      'Corrections settle as new entries in the next reconciliation.')
    throw(:abort)
  end

  def reject_destroy
    errors.add(:base, 'Reconciliations are settlement events and cannot be destroyed.')
    throw(:abort)
  end

  def number_of_meals
    meals.count
  end

  def unique_cooks
    cooks.uniq
  end

  # Assigns all unreconciled meals (with at least one bill) on or before the
  # cutoff date. Meals from days that are not yet over are never swept,
  # regardless of end_date — their receipts and attendance are not final.
  # This backstops the end_date validation for rows that predate it.
  #
  # The UPDATE re-asserts reconciliation_id IS NULL: under READ COMMITTED a
  # concurrent settlement can claim a plucked meal between the read and the
  # write, and PostgreSQL re-evaluates the predicate on the committed row
  # version after the lock wait, excluding claimed rows instead of silently
  # overwriting the rival's assignment (which would double-charge every
  # resident on those meals — both ledgers sum to zero, so no later check
  # fires). Claiming fewer rows than were plucked means that race happened:
  # raise so this settlement rolls back whole.
  def assign_meals
    meal_ids = eligible_meal_ids
    claimed = Meal.where(id: meal_ids, reconciliation_id: nil).update_all(reconciliation_id: id)
    return if claimed == meal_ids.size

    raise "assign_meals: reconciliation #{id} plucked #{meal_ids.size} " \
          "#{'meal'.pluralize(meal_ids.size)} but claimed #{claimed} — a concurrent reconciliation " \
          'settled the rest first. Rolling back to avoid settling the same meals twice.'
  end

  # Compute final settlement balances for this reconciliation period.
  # Returns a hash of { resident_id => rounded_balance }.
  # Uses largest-remainder method (Hamilton's method) to round to cents,
  # guaranteeing the total sums to exactly zero.
  #
  # This method batch-loads all data upfront (5 queries total) to avoid the N+1
  # that would result from calling Meal#unit_cost per-record. The arithmetic is
  # identical to the per-record path (Meal#unit_cost, MealResident#cost, etc.)
  # but computed from in-memory data.
  #
  # Memory: loads all reconciled meals + associations into RAM. For a co-housing
  # community (~500 meals max), this is ~18K AR objects (~36 MB). Bounded by the
  # physical size of the community.
  def settlement_balances # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- financial settlement calculation, intentionally kept as single method for auditability
    # Step 1: Eager-load all reconciled meals with their financial associations.
    # Uses preload (not includes) to guarantee separate IN(?) queries — includes
    # can silently switch to LEFT JOIN if a .where is later chained on an
    # included table, which would produce a cartesian product across 3 associations.
    reconciled_meals = meals.with_attendees.preload(:bills, :meal_residents, :guests).to_a

    # Step 2: Precompute per-meal financials from in-memory data.
    # Uses block-form .sum(&:field) which invokes Enumerable#sum on the loaded
    # array. The column-form .sum(:field) always fires SQL even when loaded.
    # Stores total_cost and effective_cost alongside unit_cost so the credit
    # calculation in Step 3 can apply proportional capping for subsidized meals.
    meal_financials = {}
    reconciled_meals.each do |meal|
      total_mult = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)

      if total_mult.zero?
        zero = BigDecimal('0')
        meal_financials[meal.id] = { unit_cost: zero, total_cost: zero, effective_cost: zero }
        next
      end

      total_cost = meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
      effective_cost = total_cost
      if meal.capped?
        max_cost = meal.cap * total_mult
        effective_cost = max_cost if total_cost > max_cost
      end

      meal_financials[meal.id] = {
        unit_cost: effective_cost / total_mult, total_cost: total_cost, effective_cost: effective_cost
      }
    end

    # Step 3: Accumulate credits, debits, and guest debits from in-memory data.
    # All three use the already-loaded associations — zero additional queries.
    # Credits use the proportional capped amount: when a meal is subsidized
    # (cook spent more than the cap), each cook's credit is their proportional
    # share of the effective (capped) cost, not the raw bill amount.
    credits_by_resident = Hash.new(BigDecimal('0'))
    debits_by_resident = Hash.new(BigDecimal('0'))
    guest_debits_by_resident = Hash.new(BigDecimal('0'))

    reconciled_meals.each do |meal|
      mf = meal_financials[meal.id]

      meal.bills.each do |b|
        next if b.no_cost

        credit = if mf[:total_cost].zero?
                   BigDecimal('0')
                 elsif mf[:effective_cost] < mf[:total_cost]
                   (b.amount / mf[:total_cost]) * mf[:effective_cost]
                 else
                   b.amount
                 end
        credits_by_resident[b.resident_id] += credit
      end

      meal.meal_residents.each { |mr| debits_by_resident[mr.resident_id] += mf[:unit_cost] * mr.multiplier }
      meal.guests.each { |g| guest_debits_by_resident[g.resident_id] += mf[:unit_cost] * g.multiplier }
    end

    # Step 4: Assemble per-resident raw balances (1 query for residents, zero inside loop).
    raw_balances = {}
    community.residents.find_each do |resident|
      credits = credits_by_resident[resident.id]
      debits = debits_by_resident[resident.id]
      guest_debits = guest_debits_by_resident[resident.id]
      raw_balances[resident.id] = credits - debits - guest_debits
    end

    # Step 5: Round to cents using largest-remainder method (Hamilton's method).
    # This guarantees rounded balances sum to exactly zero — the standard
    # accounting approach for apportioning monetary amounts. Each value is
    # within 1 cent of its exact full-precision amount.
    balances = allocate_to_cents(raw_balances)

    # Verify the books balance exactly. allocate_to_cents guarantees this;
    # a non-zero sum indicates a bug in the allocation algorithm.
    total = balances.values.sum(BigDecimal('0'))
    unless total.zero?
      raise "settlement_balances: books do not balance for reconciliation #{id}. " \
            "Discrepancy: #{total}. This indicates a bug in allocate_to_cents."
    end

    balances
  end

  # Persist settlement balances to reconciliation_balances table.
  # Idempotent: clears existing balances first, then writes fresh values.
  # Only stores non-zero balances to keep the table lean.
  def persist_balances!
    balances = settlement_balances

    transaction do
      reconciliation_balances.delete_all
      balances.each do |resident_id, amount|
        next if amount.zero?

        reconciliation_balances.create!(resident_id: resident_id, amount: amount)
      end
    end
  end

  # Settlement balances grouped by unit. Returns { [unit_id, unit_name] => BigDecimal }
  # for every community unit, including units whose residents all have $0.00 balances.
  def unit_balances
    grouped = reconciliation_balances
              .joins(resident: :unit)
              .group('units.id', 'units.name')
              .sum(:amount)

    community.units.order(:name).each_with_object({}) do |unit, result|
      key = [unit.id, unit.name]
      result[key] = grouped[key] || BigDecimal('0')
    end
  end

  def balance_for(resident)
    reconciliation_balances.find_by(resident_id: resident.id)&.amount || BigDecimal('0')
  end

  private

  def eligible_meal_ids
    Meal.unreconciled
        .joins(:bills)
        .where(date: ..end_date)
        .where(date: ...Time.zone.today)
        .distinct
        .pluck(:id)
  end

  def finalize
    assign_meals
    persist_balances!
  end

  def set_date
    self.date ||= Time.zone.today
  end

  # A reconciliation may only settle days that are over. Meals on today's date
  # (or later) may not have happened yet — cooks' receipts and attendance are
  # not final — so the cutoff must be strictly in the past (issue #3).
  def end_date_before_today
    return if end_date.blank?
    return if end_date < Time.zone.today

    errors.add(:end_date, 'must be before today — meals on that date may not have finished yet')
  end

  # Distributes full-precision balances (which sum to zero) into cent-rounded
  # balances that also sum to exactly zero, using the largest-remainder method
  # (Hamilton's method). Each rounded value is within 1 cent of its exact amount.
  #
  # Algorithm:
  # 1. Truncate each balance toward zero (floor positives, ceil negatives).
  # 2. Compute the residual = sum of truncated values (close to zero, off by a few cents).
  # 3. Award residual pennies to entries whose truncation discarded the most,
  #    tie-breaking by lowest resident_id for deterministic, auditable results.
  def allocate_to_cents(raw_balances)
    assert_balanced_input!(raw_balances)

    one_cent = BigDecimal('0.01')

    truncated = {}
    remainders = {}

    raw_balances.each do |id, raw|
      truncated[id] = raw >= 0 ? raw.floor(2) : raw.ceil(2)
      remainders[id] = raw - truncated[id]
    end

    residual = truncated.values.sum(BigDecimal('0'))
    pennies = (residual / one_cent).round.to_i

    if pennies.positive?
      # Sum too positive — subtract pennies from entries with most-negative remainders
      # (those entries benefited most from truncation toward zero).
      candidates = remainders.select { |_, r| r.negative? }.sort_by { |id, r| [r, id] }
      assert_candidates_cover_pennies!(candidates, pennies)
      pennies.times { |i| truncated[candidates[i][0]] -= one_cent }
    elsif pennies.negative?
      # Sum too negative — add pennies to entries with most-positive remainders.
      candidates = remainders.select { |_, r| r.positive? }.sort_by { |id, r| [-r, id] }
      assert_candidates_cover_pennies!(candidates, pennies.abs)
      pennies.abs.times { |i| truncated[candidates[i][0]] += one_cent }
    end

    truncated
  end

  # First defensive layer: the largest-remainder allocation is only meaningful
  # when the input already balances. A materially nonzero input sum means an
  # upstream bug — allocating anyway would silently spread the imbalance
  # across residents' settled amounts.
  def assert_balanced_input!(raw_balances)
    input_sum = raw_balances.values.sum(BigDecimal('0'))
    return if input_sum.abs <= ZERO_SUM_EPSILON

    raise "allocate_to_cents: raw balances do not sum to zero for reconciliation #{id}. " \
          "Sum: #{input_sum.to_s('F')}. This indicates an upstream bug in balance computation; " \
          'allocating pennies would silently redistribute the imbalance onto residents.'
  end

  # Second defensive layer behind the zero-sum input guard: if the residual
  # ever needs more pennies than there are fractional remainders to absorb
  # them, the books cannot balance — fail with a diagnostic instead of
  # indexing past the end of the candidate list.
  def assert_candidates_cover_pennies!(candidates, pennies_needed)
    return if pennies_needed <= candidates.size

    raise "allocate_to_cents: books do not balance for reconciliation #{id}. " \
          "#{pennies_needed} residual #{'penny'.pluralize(pennies_needed)} to allocate " \
          "but only #{candidates.size} fractional #{'remainder'.pluralize(candidates.size)} available. " \
          'This indicates an upstream bug in balance computation.'
  end
end

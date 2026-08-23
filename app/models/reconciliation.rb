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
  include BelongsToTheCommunity

  # Raw balances are computed with BigDecimal division carrying ~20+
  # significant digits, so a balanced input sums to within ~1e-15 of zero even
  # across thousands of meals. Any genuine upstream imbalance manifests at a
  # fraction of a cent or more — orders of magnitude above this epsilon.
  ZERO_SUM_EPSILON = BigDecimal('0.000001')

  # Ransack allowlists for ActiveAdmin sorting
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
  # The destroy guard aborts before the has_many dependent callbacks
  # declared above (nullify meals, destroy balances) can un-reconcile
  # anything — see AppendOnly for the prepend reasoning (issue #26).
  include AppendOnly

  append_only update_message: 'Reconciliations are settlement events and cannot be modified. ' \
                              'Corrections settle as new entries in the next reconciliation.',
              destroy_message: 'Reconciliations are settlement events and cannot be destroyed.'

  def number_of_meals
    meals.count
  end

  def unique_cooks
    cooks.uniq
  end

  # The period this settlement covers: the dates of the meals it swept.
  # Neither date column is the start of that period — `date` is the day the
  # settlement ran and `end_date` is the sweep cutoff — so a "date to
  # end_date" display reads backwards ("2026-08-10 to 2026-06-15").
  def date_range_description
    DateRangeDescription.for(meals.minimum(:date), meals.maximum(:date))
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
  #
  # The FOR UPDATE lock before the UPDATE is not redundant, and removing it
  # reopens silent corruption of the settled ledger (issue #43). The UPDATE
  # alone takes only FOR NO KEY UPDATE on the meal row, and FOR KEY SHARE —
  # what the immutability trigger's lookups take — does not conflict with
  # that. So a write from a path that skips the meal lock (ActiveAdmin's
  # forms) would have nothing to wait on, and could change a meal's ledger
  # rows while this settlement was in the middle of claiming it. Added rows
  # end up in no reconciliation's balances, and billing:recalculate skips
  # them because that task only sums unreconciled meals; deleted rows leave
  # balances behind that nothing justifies. FOR UPDATE does conflict with
  # FOR KEY SHARE, so the rival write waits here and is then refused by the
  # trigger.
  #
  # This works only together with the trigger's two unconditional locking
  # lookups (20260727120000). Without the NEW.meal_id one, an insert decides
  # too early — Postgres fires BEFORE INSERT triggers before the foreign-key
  # check — and lands anyway once the FK wait ends. Without the OLD.meal_id
  # one, a delete never waits at all, because a DELETE takes no foreign-key
  # lock on the parent. Each piece alone was tested and does not close the
  # hole. See docs/adr/0003-concurrency-on-the-money-path.md.
  #
  # ORDER BY id keeps the lock order deterministic so two concurrent
  # settlements cannot deadlock against each other.
  def assign_meals
    meal_ids = eligible_meal_ids
    Meal.where(id: meal_ids).order(:id).lock.pluck(:id)
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
  # The arithmetic itself is MealLedger's, which the running-balance rake task
  # also uses. This method is only the settlement-specific part: which meals,
  # which residents, and the rounding to cents.
  #
  # Memory: loads all reconciled meals + associations into RAM. For a co-housing
  # community (~500 meals max), this is ~18K AR objects (~36 MB). Bounded by the
  # physical size of the community.
  def settlement_balances(ledger = settlement_ledger)
    raw_balances = ledger.balances(community.residents.pluck(:id))

    # Round to cents using largest-remainder method (Hamilton's method).
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

  # The meals this reconciliation settled, loaded once with everything the
  # arithmetic needs.
  #
  # Uses preload (not includes) to guarantee separate IN(?) queries — includes
  # can silently switch to LEFT JOIN if a .where is later chained on an
  # included table, which would produce a cartesian product across 3
  # associations. MealLedger runs no queries of its own, so these three
  # associations must be loaded before it sees the meals.
  def settlement_ledger
    MealLedger.new(meals.with_attendees.preload(:bills, :meal_residents, :guests).to_a)
  end

  # Write the settlement: the line items, then the balances they add up to.
  # Runs once, from finalize, inside the transaction that creates the
  # reconciliation.
  #
  # Both tables come from one MealLedger pass. Computing them separately would
  # mean two reads of the same meals with a gap between them, and the whole
  # point of storing the lines is that they explain the balances — which they
  # cannot do if they were derived from a different read.
  #
  # Only non-zero balances are stored, which keeps that table lean and costs
  # nothing: a resident with no row owes and is owed nothing. Every line is
  # stored, including zero ones, because a zero line is still a fact about
  # what happened — a resident who ate a meal that cost nothing.
  #
  # This is not idempotent, and should not be. A settled balance is what a
  # resident has already been billed, so re-running it would rewrite the
  # ledger rather than correct it. Re-running is refused twice over: the
  # deletes by the triggers in 20260731120000 and 20260802120000, and the
  # re-inserts by the unique indexes on both tables. To rebuild a
  # reconciliation on purpose, see docs/runbooks/settled-data-repair.md.
  def persist_settlement!
    ledger = settlement_ledger

    transaction do
      persist_charges!(ledger)
      persist_balances!(ledger)
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

  private

  # The meals this reconciliation would sweep. Both the create validation and
  # assign_meals read this one scope, so they cannot disagree about what
  # "eligible" means. A second copy of the predicate could drift, and then a
  # reconciliation would pass validation and go on to claim zero meals.
  def eligible_meals
    Meal.unreconciled
        .joins(:bills)
        .where(date: ..end_date)
        .where(date: ...Time.zone.today)
        .distinct
  end

  def eligible_meal_ids
    eligible_meals.pluck(:id)
  end

  def finalize
    assign_meals
    persist_settlement!
  end

  # One row per source row: one credit per bill, one debit per attendance,
  # one per guest. insert_all rather than create! because these are written
  # in a batch and there is nothing per-row to validate that the check
  # constraints and MealLedger do not already guarantee — and a settlement
  # writes a few hundred of them.
  def persist_charges!(ledger)
    lines = ledger.lines
    return if lines.empty?

    now = Time.current
    MealCharge.insert_all(
      lines.map do |line|
        {
          meal_id: line.meal_id, resident_id: line.resident_id, kind: line.kind.to_s,
          amount: line.amount, multiplier: line.multiplier, unit_cost: line.unit_cost,
          bill_amount: line.bill_amount, created_at: now, updated_at: now
        }
      end
    )
  end

  def persist_balances!(ledger)
    settlement_balances(ledger).each do |resident_id, amount|
      next if amount.zero?

      reconciliation_balances.create!(resident_id: resident_id, amount: amount)
    end
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
  def must_settle_at_least_one_meal
    return if end_date.blank?
    return if errors[:end_date].any?
    return if eligible_meals.exists?

    errors.add(:base, 'No unreconciled meals with bills on or before this date. ' \
                      'A reconciliation must settle at least one meal.')
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

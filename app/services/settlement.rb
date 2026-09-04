# typed: strict
# frozen_string_literal: true

# Settles a billing period.
#
# One call does the whole job, in one database transaction: it creates the
# Reconciliation row, claims every meal the period covers, computes each
# resident's charges with MealLedger, rounds the per-resident totals to
# cents, and writes meal_charges and reconciliation_balances. If any part
# fails, none of it happened — there is never a reconciliation row without
# its ledger, and never a claimed meal without a reconciliation.
#
#   Settlement.run!(cutoff: community.yesterday)   # the rake task, the API
#   Settlement.new(reconciliation).settle!    # a built row (the admin form,
#                                             # the factory)
#   Settlement.new(reconciliation).rewrite!   # repair only: rewrite the
#                                             # ledger of an existing row
#                                             # (docs/runbooks/settled-data-repair.md)
#
# This used to be an after_create callback on Reconciliation, so creating
# the row settled the period as a side effect. It is a service now so that
# the pipeline has a name, so the same arithmetic can run without writing
# anything (a preview), and so the cutoff can come from a caller instead of
# always being yesterday. Reconciliation refuses to be created any other
# way (Reconciliation::NotSettled).
#
# The money rules this enforces are in CLAUDE.md ("Money Handling
# Standards"); the concurrency rules are in docs/adr/0003 and 0005.
class Settlement
  extend T::Sig

  # Raised by preview for a cutoff that run! would refuse, with the same
  # words the model's validation uses.
  class InvalidCutoff < ArgumentError; end

  # Raised when a concurrent settlement claimed one of this settlement's
  # meals first. Everything rolls back; the request can simply be sent again.
  class Contested < RuntimeError; end

  sig { params(cutoff: Date, community: Community).returns(Reconciliation) }
  def self.run!(cutoff:, community: Community.instance)
    new(Reconciliation.new(community: community, end_date: cutoff)).settle!
  end

  # What run! would settle and store for this cutoff, computed without
  # writing anything. The meals are the same scope run! claims
  # (Meal.settleable_by), the arithmetic is the same MealLedger pass, and
  # the rounding is the same allocate_to_cents, so a preview's balances are
  # exactly the rows a run! on the same data would store — a spec pins that.
  #
  # Returns a Preview: the cutoff, the meals with their ledger and their
  # cooks preloaded, the ledger itself (for per-meal summaries), the
  # rounded per-resident balances for every resident in the community
  # (zero included, so a screen can show everyone), and the meals the
  # settlement would leave behind.
  #
  # skipped_meals are the meals in the period that people ate but no cook
  # billed. A settlement never claims a meal without a bill, so these stay
  # unreconciled — past this settlement and every later one — until someone
  # enters a bill, and nobody who ate is charged. They are not in `meals`
  # (nothing about them settles); they are here so the preview can warn.
  class Preview < T::Struct
    extend T::Sig

    const :cutoff, Date
    const :meals, T::Array[Meal]
    const :ledger, MealLedger
    const :resident_balances, T::Hash[Integer, BigDecimal]
    const :skipped_meals, T::Array[Meal]

    sig { params(meal: Meal).returns(MealLedger::Summary) }
    def meal_summary(meal) = ledger.summary_for(meal)
  end

  sig { params(cutoff: Date, community: Community).returns(Preview) }
  def self.preview(cutoff:, community: Community.instance)
    raise InvalidCutoff, 'cutoff must be in the past' unless cutoff < community.today

    meals = Meal.settleable_by(cutoff, today: community.today).order(:date).preload({ bills: :resident },
                                                                                    :meal_residents, :guests).to_a
    ledger = MealLedger.new(meals)
    raw = ledger.balances(community.residents.pluck(:id))
    Preview.new(cutoff: cutoff, meals: meals, ledger: ledger,
                resident_balances: allocate_to_cents(raw, reconciliation_id: 'preview'),
                skipped_meals: skipped_by(cutoff, today: community.today))
  end

  # Unreconciled meals in the period with attendance and no bill at all.
  # The date rules are settleable_by's; the difference is the missing bill.
  sig { params(cutoff: Date, today: Date).returns(T::Array[Meal]) }
  def self.skipped_by(cutoff, today:)
    Meal.unreconciled.where(date: ..cutoff).where(date: ...today)
        .where.missing(:bills).with_attendees
        .order(:date).preload(:meal_residents, :guests).to_a
  end

  sig { returns(Reconciliation) }
  attr_reader :reconciliation

  sig { params(reconciliation: Reconciliation).void }
  def initialize(reconciliation)
    @reconciliation = reconciliation
    @claimed_meal_ids = T.let(nil, T.nilable(T::Array[Integer]))
  end

  # Create the row, claim the meals, write the ledger. Raises
  # ActiveRecord::RecordInvalid when the period is not settleable (cutoff
  # not in the past, or no meal to settle), and RuntimeError when a
  # concurrent settlement claimed a meal first; both roll everything back.
  sig { returns(Reconciliation) }
  def settle!
    reconciliation.mark_settling!

    Reconciliation.transaction do
      reconciliation.save!
      assign_meals
      write_ledger!
    end

    forget_cached_meals
    reconciliation
  end

  # Repair only. Writes the line items and balances for a reconciliation
  # that already exists and already claimed its meals. Not re-runnable on
  # its own — the caller clears both tables first, inside one transaction,
  # with the settled-write bypass on. See the runbook.
  sig { void }
  def rewrite!
    write_ledger!
  end

  # The name a preview passes as the reconciliation id in error messages,
  # since it has no row.
  ReconciliationRef = T.type_alias { T.nilable(T.any(Integer, String)) }

  # Distributes full-precision balances (which sum to zero) into cent-rounded
  # balances that also sum to exactly zero, using the largest-remainder method
  # (Hamilton's method). Each rounded value is within 1 cent of its exact amount.
  #
  # Algorithm:
  # 1. Truncate each balance toward zero (floor positives, ceil negatives).
  # 2. Compute the residual = sum of truncated values (close to zero, off by a few cents).
  # 3. Award residual pennies to entries whose truncation discarded the most,
  #    tie-breaking by lowest resident_id for deterministic, auditable results.
  #
  # A class method because Reconciliation#settlement_balances (the read side,
  # used by ledger:verify) rounds the same way.
  sig do
    params(raw_balances: T::Hash[Integer, BigDecimal], reconciliation_id: ReconciliationRef)
      .returns(T::Hash[Integer, BigDecimal])
  end
  def self.allocate_to_cents(raw_balances, reconciliation_id: nil)
    assert_balanced_input!(raw_balances, reconciliation_id)

    one_cent = BigDecimal('0.01')
    truncated, remainders = truncate_toward_zero(raw_balances)

    residual = truncated.values.sum(BigDecimal('0'))
    pennies = (residual / one_cent).round.to_i

    if pennies.positive?
      # Sum too positive — subtract pennies from entries with most-negative remainders
      # (those entries benefited most from truncation toward zero).
      candidates = remainders.select { |_, r| r.negative? }.sort_by { |id, r| [r, id] }
      assert_candidates_cover_pennies!(candidates, pennies, reconciliation_id)
      pennies.times { |i| adjust!(truncated, candidates.fetch(i).first, -one_cent) }
    elsif pennies.negative?
      # Sum too negative — add pennies to entries with most-positive remainders.
      candidates = remainders.select { |_, r| r.positive? }.sort_by { |id, r| [-r, id] }
      assert_candidates_cover_pennies!(candidates, pennies.abs, reconciliation_id)
      pennies.abs.times { |i| adjust!(truncated, candidates.fetch(i).first, one_cent) }
    end

    truncated
  end

  # First defensive layer: the largest-remainder allocation is only meaningful
  # when the input already balances. A materially nonzero input sum means an
  # upstream bug — allocating anyway would silently spread the imbalance
  # across residents' settled amounts.
  # Step 1: each balance cut to whole cents, and what the cut discarded.
  sig do
    params(raw_balances: T::Hash[Integer, BigDecimal])
      .returns([T::Hash[Integer, BigDecimal], T::Hash[Integer, BigDecimal]])
  end
  def self.truncate_toward_zero(raw_balances)
    truncated = T.let({}, T::Hash[Integer, BigDecimal])
    remainders = T.let({}, T::Hash[Integer, BigDecimal])

    raw_balances.each do |id, raw|
      truncated[id] = raw >= 0 ? raw.floor(2) : raw.ceil(2)
      remainders[id] = raw - truncated.fetch(id)
    end

    [truncated, remainders]
  end

  sig { params(balances: T::Hash[Integer, BigDecimal], id: Integer, delta: BigDecimal).void }
  def self.adjust!(balances, id, delta)
    balances[id] = balances.fetch(id) + delta
  end

  sig { params(raw_balances: T::Hash[Integer, BigDecimal], reconciliation_id: ReconciliationRef).void }
  def self.assert_balanced_input!(raw_balances, reconciliation_id)
    input_sum = raw_balances.values.sum(BigDecimal('0'))
    return if input_sum.abs <= Reconciliation::ZERO_SUM_EPSILON

    raise "allocate_to_cents: raw balances do not sum to zero for reconciliation #{reconciliation_id}. " \
          "Sum: #{input_sum.to_s('F')}. This indicates an upstream bug in balance computation; " \
          'allocating pennies would silently redistribute the imbalance onto residents.'
  end

  # Second defensive layer behind the zero-sum input guard: if the residual
  # ever needs more pennies than there are fractional remainders to absorb
  # them, the books cannot balance — fail with a diagnostic instead of
  # indexing past the end of the candidate list.
  sig do
    params(candidates: T::Array[[Integer, BigDecimal]], pennies_needed: Integer, reconciliation_id: ReconciliationRef)
      .void
  end
  def self.assert_candidates_cover_pennies!(candidates, pennies_needed, reconciliation_id)
    return if pennies_needed <= candidates.size

    raise "allocate_to_cents: books do not balance for reconciliation #{reconciliation_id}. " \
          "#{pennies_needed} residual #{'penny'.pluralize(pennies_needed)} to allocate " \
          "but only #{candidates.size} fractional #{'remainder'.pluralize(candidates.size)} available. " \
          'This indicates an upstream bug in balance computation.'
  end

  private_class_method :truncate_toward_zero, :adjust!, :assert_balanced_input!, :assert_candidates_cover_pennies!

  private

  # Assigns all unreconciled meals (with at least one bill) on or before the
  # cutoff date. Meals from days that are not yet over are never swept,
  # regardless of the cutoff — their receipts and attendance are not final.
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
  sig { void }
  def assign_meals
    meal_ids = eligible_meal_ids
    Meal.where(id: meal_ids).order(:id).lock.pluck(:id)
    claimed = Meal.where(id: meal_ids, reconciliation_id: nil).update_all(reconciliation_id: reconciliation.id)
    @claimed_meal_ids = meal_ids
    return if claimed == meal_ids.size

    raise Contested, "assign_meals: reconciliation #{reconciliation.id} plucked #{meal_ids.size} " \
                     "#{'meal'.pluralize(meal_ids.size)} but claimed #{claimed} — a concurrent reconciliation " \
                     'settled the rest first. Rolling back to avoid settling the same meals twice.'
  end

  # The same scope the create validation reads (Reconciliation#eligible_meals),
  # so the two cannot disagree about which meals count.
  sig { returns(T::Array[Integer]) }
  def eligible_meal_ids
    reconciliation.eligible_meals.pluck(:id)
  end

  # Write the settlement: the line items, then the balances they add up to.
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
  sig { void }
  def write_ledger!
    ledger = reconciliation.settlement_ledger

    Reconciliation.transaction do
      persist_charges!(ledger)
      persist_balances!(ledger)
    end
  end

  # One row per source row: one credit per bill, one debit per attendance,
  # one per guest. insert_all rather than create! because these are written
  # in a batch and there is nothing per-row to validate that the check
  # constraints and MealLedger do not already guarantee — and a settlement
  # writes a few hundred of them.
  sig { params(ledger: MealLedger).void }
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

  sig { params(ledger: MealLedger).void }
  def persist_balances!(ledger)
    reconciliation.settlement_balances(ledger).each do |resident_id, amount|
      next if amount.zero?

      reconciliation.reconciliation_balances.create!(resident_id: resident_id, amount: amount)
    end
  end

  # A settled meal is frozen: its page says `reconciled` and locks its
  # forms, and its calendar month is cached. Nothing else tells the
  # clients, because the claim is an update_all that fires no callbacks
  # (issue #70). Runs after the transaction commits, so no reader can
  # refill a cache from a claim that then rolled back. LiveUpdate clears
  # every month before the first push, and a push that fails is reported,
  # not raised — the ledger is committed by the time this runs, and a
  # raise here would make the caller skip the balance refresh and the
  # cook emails (SettleAndNotify) for a settlement that is in the
  # database.
  sig { void }
  def forget_cached_meals
    ids = @claimed_meal_ids
    return if ids.blank?

    LiveUpdate.batch do
      Meal.where(id: ids).pluck(:id, :date).each do |id, date|
        LiveUpdate.meal(id, socket_id: nil)
        LiveUpdate.calendar(date)
      end
    end
  end
end

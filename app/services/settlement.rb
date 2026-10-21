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
#   Settlement.run!(cutoff: cutoff)           # the seeds
#   Settlement.settle!(cutoff: cutoff)        # SettleAndNotify: the rake
#                                             # task, the API, the admin form
#   Settlement.settle!(cutoff: cutoff, fingerprint: preview.fingerprint)
#                                             # the admin form: refuse if
#                                             # anything changed since the
#                                             # preview
#   Settlement.new(reconciliation).settle!    # a built row (the factory)
#   Settlement.new(reconciliation).rewrite!   # repair only: rewrite the
#                                             # ledger of an existing row
#                                             # (docs/runbooks/settled-data-repair.md)
#   Settlement.new(reconciliation).correct!(reason: '...') { fix the rows }
#                                             # fix a settled period's rows,
#                                             # work it out again, and record
#                                             # what changed
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
  include SettlementCorrecting

  # Raised by preview for a cutoff that run! would refuse. Its words are
  # the ones POST /reconciliations answers for the same cutoff: "cutoff",
  # then the model validation's message (Reconciliation.cutoff_refusal).
  class InvalidCutoff < ArgumentError; end

  # Raised when a concurrent settlement claimed one of this settlement's
  # meals first. Everything rolls back; the request can simply be sent again.
  class Contested < RuntimeError; end

  # Raised by settle! when the caller passed the fingerprint of a preview
  # and the settlement would claim other meals, or store other amounts,
  # than that preview showed. Someone changed a cost or a sign-up after
  # the preview was made. Everything rolls back.
  class Changed < RuntimeError; end

  # Raised by correct! when the settlement already disagreed with its rows
  # before the caller's fix. Nothing is written.
  class EarlierDifference < RuntimeError; end

  # Settlement#correct! was asked to work out again a settlement with a
  # line marked Paid or Let go (ADR 0011 rule 8). Once people pay from a
  # settlement, its numbers stay what they were; a mistake found later is
  # a correction in the next settlement (rule 6).
  class Marked < RuntimeError; end

  # Settlement#correct! was asked to work out again a settlement one of
  # whose dinners has a correction (ADR 0011 rule 6). From that
  # correction on, the settlement keeps what it settled and the
  # corrections carry every change. Nothing is written.
  class DinnerCorrected < RuntimeError; end

  # Raised by correct! when its fix block was left by return, break or
  # throw. Rails commits a transaction block that is left without an
  # error, so the fix would stay on the settled rows with no correction
  # and no new numbers. Raising rolls the savepoint back. Nothing is
  # written.
  class FixLeftEarly < RuntimeError; end

  # The name of the database setting that says which settlement is writing.
  # write_ledger! sets it to the reconciliation's id while it writes the
  # line items and balances, and the database refuses an insert into
  # either table unless this setting names the reconciliation the row
  # belongs to, or the repair bypass is on (migration 20261009120000).
  SETTLING_SETTING = 'comeals.settling'

  # The repair bypass (docs/runbooks/settled-data-repair.md). correct!
  # turns it on for its two deletes only.
  BYPASS_SETTING = 'comeals.allow_settled_writes'

  # Settle the period and clear the settled meals from the caches. For a
  # caller with no retry around it (the seed task).
  sig { params(cutoff: Date).returns(Reconciliation) }
  def self.run!(cutoff:)
    settlement = settle!(cutoff: cutoff)
    settlement.forget_cached_meals
    settlement.reconciliation
  end

  # Settle the period and stop at the commit. For a caller that retries
  # the commit on a conflict (SettleAndNotify): it calls
  # forget_cached_meals itself, after the retry, so nothing that runs
  # after the commit can be taken for a failed commit and settle the
  # period again. A caller that opens its own transaction around this
  # one adds its writes to the settlement's commit.
  #
  # With a fingerprint (Preview#fingerprint), it settles only what that
  # preview showed, and raises Changed otherwise.
  sig { params(cutoff: Date, fingerprint: T.nilable(String)).returns(Settlement) }
  def self.settle!(cutoff:, fingerprint: nil)
    new(Reconciliation.new(end_date: cutoff)).tap { |settlement| settlement.settle!(fingerprint: fingerprint) }
  end

  # A short code made from what a settlement at this cutoff claims and
  # stores: the cutoff, the meals, the corrections it carries, and each
  # person's amount rounded to cents. The admin form shows a preview, then
  # sends the preview's code with Create, and settle! makes the code again
  # from what it is about to commit. If a cost or a sign-up changed in
  # between and that changed which meals settle or moved a cent for
  # someone, the codes differ and nothing is saved, so an admin never
  # settles amounts they did not see (ADR 0011 rule 4). A change that
  # moves no cent (a sign-up on a meal whose cooks all marked No cost)
  # leaves the code the same, and the settlement saves it.
  #
  # The amounts are the cent-rounded balances, not the meal lines. A
  # preview's lines include a meal nobody ate (credits of $0), and a
  # settlement writes no lines for it, so the lines of the two can differ
  # when nothing did. The balances cannot: a spec pins that a preview's
  # balances are the rows a settlement stores. A $0 balance is left out
  # on both sides, because a settlement stores none.
  sig do
    params(cutoff: Date, meal_ids: T::Array[Integer], correction_ids: T::Array[Integer],
           balances: T::Hash[Integer, BigDecimal]).returns(String)
  end
  def self.fingerprint(cutoff:, meal_ids:, correction_ids:, balances:)
    amounts = balances.reject { |_, amount| amount.zero? }.sort.map { |id, amount| "#{id}:#{amount.to_s('F')}" }
    Digest::SHA256.hexdigest([cutoff.iso8601, meal_ids.sort.join(','), correction_ids.sort.join(','),
                              amounts.join(',')].join('|'))
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
  # settlement would leave behind, by reason.
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
    # Left behind the other way round: a receipt with money on it and nobody
    # to charge, because nobody signed up or everyone who did eats free
    # (Meal.receipt_and_nobody_to_charge). Also not in `meals`.
    const :held_meals, T::Array[Meal]
    # Left behind until every cook enters a cost or marks No cost: someone
    # is charged and a cook's cost is blank (Meal.waiting_for_a_cost, ADR
    # 0011 rule 3). Also not in `meals`.
    const :waiting_meals, T::Array[Meal]
    # Corrections to dinners already settled, which no settlement carries
    # yet (ADR 0011 rule 6). The settlement carries every one of them, and
    # their lines are in resident_balances.
    const :corrections, T::Array[MealCorrection]

    sig { params(meal: Meal).returns(MealLedger::Summary) }
    def meal_summary(meal) = ledger.summary_for(meal)

    # What the admin form sends with Create (Settlement.fingerprint).
    sig { returns(String) }
    def fingerprint
      Settlement.fingerprint(cutoff: cutoff, meal_ids: meals.map { |meal| T.must(meal.id) },
                             correction_ids: corrections.map { |correction| T.must(correction.id) },
                             balances: resident_balances)
    end
  end

  sig { params(cutoff: Date, community: Community).returns(Preview) }
  def self.preview(cutoff:, community: Community.instance)
    today = community.today
    refusal = Reconciliation.cutoff_refusal(cutoff, today)
    raise InvalidCutoff, "cutoff #{refusal}" if refusal

    # settleable_by reads today from the one community itself, the same
    # value as community.today (mutant showed passing it changed nothing,
    # 2026-09-28: the check above already keeps today out of the period).
    meals = Meal.settleable_by(cutoff).order(:date).preload({ bills: :resident }, :meal_residents, :guests).to_a
    ledger = MealLedger.new(meals)
    corrections = MealCorrection.waiting.order(:id).preload(:meal, :admin_user, lines: :resident).to_a
    # Every resident has an entry, so every correction line's person does.
    raw = ledger.balances(community.residents.pluck(:id))
    corrections.flat_map(&:lines).each do |line|
      raw[T.must(line.resident_id)] = raw.fetch(T.must(line.resident_id)) + T.must(line.amount)
    end
    Preview.new(cutoff: cutoff, meals: meals, ledger: ledger,
                resident_balances: allocate_to_cents(raw, reconciliation_id: 'preview'),
                skipped_meals: skipped_by(cutoff, today: today), held_meals: held_by(cutoff, today: today),
                waiting_meals: waiting_by(cutoff, today: today), corrections: corrections)
  end

  # Unreconciled meals in the period with attendance and no bill at all.
  # The date rules are settleable_by's; the difference is the missing bill.
  # A cancelled dinner is not skipped: it settles with no cook (ADR 0011
  # rule 11).
  sig { params(cutoff: Date, today: Date).returns(T::Array[Meal]) }
  def self.skipped_by(cutoff, today:)
    Meal.unreconciled.not_cancelled.where(date: ..cutoff).where(date: ...today)
        .where.missing(:bills).with_attendees
        .order(:date).preload(:meal_residents, :guests).to_a
  end

  # Unreconciled meals in the period held back for a receipt nobody can be
  # charged for. The date rules are settleable_by's. The attendance comes
  # along so the warning can say whether nobody signed up or only people
  # who eat free did. A held meal has no guest, because any guest is
  # someone to charge.
  sig { params(cutoff: Date, today: Date).returns(T::Array[Meal]) }
  def self.held_by(cutoff, today:)
    Meal.unreconciled.where(date: ..cutoff).where(date: ...today)
        .receipt_and_nobody_to_charge.order(:date).preload({ bills: :resident }, :meal_residents).to_a
  end

  # Unreconciled meals in the period waiting for a cook's cost. The date
  # rules are settleable_by's. The cooks come along so the warning can
  # name each cook whose cost is blank.
  sig { params(cutoff: Date, today: Date).returns(T::Array[Meal]) }
  def self.waiting_by(cutoff, today:)
    Meal.unreconciled.where(date: ..cutoff).where(date: ...today)
        .waiting_for_a_cost.order(:date).preload(bills: :resident).to_a
  end

  sig { returns(Reconciliation) }
  attr_reader :reconciliation

  sig { params(reconciliation: Reconciliation).void }
  def initialize(reconciliation)
    @reconciliation = reconciliation
    @claimed_meals = T.let(nil, T.nilable(T::Array[[Integer, Date]]))
    @claimed_corrections = T.let(nil, T.nilable(T::Array[Integer]))
  end

  # The id and date of each meal this settlement claimed, read under the
  # meals' row locks inside its transaction (assign_meals). Kept so that
  # nothing after the commit has to read the meals again: the cache clear
  # and the answer to the person who settled both come from here, and a
  # read after the commit is a read that can fail for a settlement that
  # is saved. Empty only for a settlement that carries corrections and
  # settles no meal: reconciliation.save! refuses one with neither.
  sig { returns(T::Array[[Integer, Date]]) }
  def claimed_meals = T.must(@claimed_meals)

  # The ids of the corrections this settlement claimed (ADR 0011 rule 6),
  # read under their row locks inside its transaction.
  sig { returns(T::Array[Integer]) }
  def claimed_corrections = T.must(@claimed_corrections)

  # How many meals this settlement claimed. The same number as
  # reconciliation.number_of_meals, without a query.
  sig { returns(Integer) }
  def meal_count = claimed_meals.size

  # Create the row, claim the meals, write the ledger. Raises
  # ActiveRecord::RecordInvalid when the period is not settleable (cutoff
  # less than 14 days back, or no meal to settle), Contested when a
  # concurrent settlement claimed a meal first, and Changed when a
  # fingerprint was given and what this settlement wrote does not match
  # it; each rolls everything back. Does nothing after the commit; the
  # caller runs forget_cached_meals. Returns nothing: every caller already
  # holds the row, as `reconciliation`, and the meals, as claimed_meals.
  #
  # The fingerprint is checked after the writes, from the meals claimed
  # under their locks and the balances just stored, so it describes
  # exactly what would commit.
  sig { params(fingerprint: T.nilable(String)).void }
  def settle!(fingerprint: nil)
    reconciliation.mark_settling!

    Reconciliation.transaction do
      reconciliation.save!
      assign_meals
      SettledMealHistory.record(meal_ids: claimed_meals.map(&:first), reconciliation_id: T.must(reconciliation.id))
      claim_corrections
      balances = write_ledger!
      refuse_what_the_preview_did_not_show!(fingerprint, balances) if fingerprint
    end
  end

  # Repair only. Writes the line items and balances for a reconciliation
  # that already exists and already claimed its meals. Not re-runnable on
  # its own — the caller clears both tables first, inside one transaction,
  # with the settled-write bypass on. See the runbook.
  #
  # `units` is the saved unit of each person (Reconciliation#saved_units),
  # read before the caller cleared the lines; anyone it leaves out gets
  # their unit as it is now (ADR 0011 rule 7).
  sig { params(units: T::Hash[Integer, Reconciliation::SavedUnit]).void }
  def rewrite!(units: {})
    write_ledger!(units: units)
  end

  # The name a preview passes as the reconciliation id in error messages,
  # since it has no row.
  ReconciliationRef = T.type_alias { T.nilable(T.any(Integer, String)) }

  # Distributes balances at the ledger grain (which sum to exactly zero) into
  # cent-rounded balances that also sum to exactly zero, using the
  # largest-remainder method (Hamilton's method). Each rounded value is
  # less than 1 cent from its exact amount: a cent is moved only to a value
  # whose cut to cents dropped something, and it moves that value back
  # toward its exact amount. LedgerVerification relies on this, and treats
  # a gap of a whole cent as an edit. LargestRemainderSplit is the same
  # rule at the ledger grain; this one differs in that its input is signed,
  # so it truncates toward zero rather than down.
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
  def self.allocate_to_cents(raw_balances, reconciliation_id:)
    assert_balanced_input!(raw_balances, reconciliation_id)

    one_cent = BigDecimal('0.01')
    truncated, remainders = truncate_toward_zero(raw_balances)

    # Every truncated value is whole cents, so the residual is too.
    residual = truncated.values.sum(BigDecimal('0'))
    pennies = (residual / one_cent).to_i

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

  # First defensive layer: the largest-remainder allocation is only
  # meaningful when the input already balances. A meal's lines sum to
  # exactly zero (MODELS.md, "The ledger grain"), so a nonzero input sum,
  # however small, means an upstream bug — allocating anyway would spread
  # the imbalance across residents' settled amounts, and nothing would
  # report it.
  sig { params(raw_balances: T::Hash[Integer, BigDecimal], reconciliation_id: ReconciliationRef).void }
  def self.assert_balanced_input!(raw_balances, reconciliation_id)
    input_sum = raw_balances.values.sum(BigDecimal('0'))
    return if input_sum.zero?

    raise "allocate_to_cents: raw balances do not sum to zero for reconciliation #{reconciliation_id}. " \
          "Sum: #{input_sum.to_s('F')}. This indicates an upstream bug in balance computation; " \
          'allocating pennies anyway would move the imbalance onto the residents, and nothing would report it.'
  end

  # Second defensive layer behind the zero-sum input guard. With an input
  # that sums to exactly zero there are always enough remainders of the
  # needed sign to absorb the leftover pennies (each remainder is less than
  # a cent, so the ones of that sign outnumber the pennies). This is what
  # runs if the first guard is ever loosened: fail with a diagnostic instead
  # of indexing past the end of the candidate list.
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

  # A settled meal is frozen: its page says `reconciled` and locks its
  # forms, and its calendar month is cached. Nothing else tells the
  # clients, because the claim is an update_all that fires no callbacks
  # (issue #70). Runs after the transaction commits, so no reader can
  # refill a cache from a claim that then rolled back. LiveUpdate clears
  # every month before the first push, and nothing in its flush raises —
  # the ledger is committed by the time this runs, and a raise here would
  # reach the person who settled as an error for a settlement that is in
  # the database. The meals come from claimed_meals, not from a new read,
  # for the same reason. Not called from settle!, so a caller that
  # retries the commit can run it after the retry.
  sig { void }
  def forget_cached_meals
    LiveUpdate.batch do
      claimed_meals.each do |id, date|
        LiveUpdate.meal(id, socket_id: nil, push_token: nil)
        LiveUpdate.calendar(date)
      end
    end
  end

  private

  # Assigns all unreconciled meals (with at least one bill) on or before the
  # cutoff date that Meal.settleable_by does not hold back. Meals from days
  # that are not yet over are never swept, regardless of the cutoff — their
  # receipts and attendance are not final. This backstops the end_date
  # validation for rows that predate it.
  #
  # The UPDATE re-asserts reconciliation_id IS NULL: under READ COMMITTED a
  # concurrent settlement can claim a plucked meal between the read and the
  # write, and PostgreSQL re-evaluates the predicate on the committed row
  # version after the lock wait, excluding claimed rows instead of
  # overwriting the other settlement's assignment with no error (which would
  # double-charge every resident on those meals — both ledgers sum to zero,
  # so no later check fails). Claiming fewer rows than were plucked means
  # that race happened: raise so this settlement rolls back whole.
  #
  # The FOR UPDATE lock before the UPDATE is not redundant. Removing it
  # brings back issue #43: the settled ledger can be changed with no error.
  # The UPDATE alone takes only FOR NO KEY UPDATE on the meal row, and FOR
  # KEY SHARE — what LocksItsMealFirst takes before a model write — does not
  # conflict with that. So a write from a path that skips the meal lock
  # (ActiveAdmin's forms) would have nothing to wait on, and could change a
  # meal's ledger rows while this settlement was in the middle of claiming
  # it. Added rows end up in no reconciliation's balances, and
  # billing:recalculate skips them because that task only sums unreconciled
  # meals; deleted rows leave balances behind that nothing justifies. FOR
  # UPDATE conflicts with FOR KEY SHARE and with the trigger's update of the
  # meal row, so the rival write waits here and is then refused by the
  # trigger.
  #
  # This works only together with the trigger's two unconditional meal
  # lookups. Without the NEW.meal_id one, an insert decides too early —
  # Postgres fires BEFORE INSERT triggers before the foreign-key check — and
  # lands anyway once the FK wait ends. Without the OLD.meal_id one, a
  # delete never waits at all, because a DELETE takes no foreign-key lock on
  # the parent. Each piece alone was tested and does not close the hole.
  #
  # Each lookup updates the meal row (updated_at = updated_at, migration
  # 20261016120000), not only reads it (20260727120000). That covers the
  # other order: a raw write, from psql at READ COMMITTED, that started
  # before this settlement. This settlement waits for it at FOR UPDATE, but
  # its SERIALIZABLE snapshot was taken before the wait. A lock changes no
  # row, so after a read-only lookup the wait ended with no conflict, and
  # this settlement stored balances without the write. The update changes
  # the meal row, so this FOR UPDATE now fails as a conflict, and
  # SettleAndNotify tries again with a fresh snapshot
  # (spec/db/settlement_after_a_raw_write_race_spec.rb). See
  # docs/adr/0003-concurrency-on-the-money-path.md.
  #
  # ORDER BY id keeps the lock order deterministic so two concurrent
  # settlements cannot deadlock against each other.
  #
  # The locking read also takes each meal's date, for claimed_meals: read
  # under the lock, the dates are the ones this settlement claims.
  sig { void }
  def assign_meals
    meal_ids = eligible_meal_ids
    locked = T.let(Meal.where(id: meal_ids).order(:id).lock.pluck(:id, :date), T::Array[[Integer, Date]])
    claimed = Meal.where(id: meal_ids, reconciliation_id: nil).update_all(reconciliation_id: reconciliation.id)
    @claimed_meals = locked
    return if claimed == meal_ids.size

    raise Contested, "assign_meals: reconciliation #{reconciliation.id} plucked #{meal_ids.size} " \
                     "#{'meal'.pluralize(meal_ids.size)} but claimed #{claimed} — a concurrent reconciliation " \
                     'settled the rest first. Rolling back to avoid settling the same meals twice.'
  end

  # Claims every correction no settlement carries yet (ADR 0011 rule 6),
  # the way assign_meals claims meals: FOR UPDATE in id order, then an
  # UPDATE that sets reconciliation_id only where it is still empty, and
  # Contested if a rival settlement claimed one first. So a correction
  # saved while this settlement runs is carried by exactly one
  # settlement: this one if it committed before the locking read, the
  # next one otherwise. The database lets the claim through only while
  # SETTLING_SETTING names this settlement (20261010125951), so the
  # setting is on for the UPDATE only, in its own savepoint, as in
  # write_ledger!.
  sig { void }
  def claim_corrections
    ids = T.let(MealCorrection.waiting.order(:id).lock.pluck(:id), T::Array[Integer])
    @claimed_corrections = ids
    return if ids.empty?

    claimed = Reconciliation.transaction(requires_new: true) do
      write_settling_setting(T.must(reconciliation.id).to_s)
      count = MealCorrection.where(id: ids, reconciliation_id: nil)
                            .update_all(reconciliation_id: reconciliation.id, updated_at: Time.current)
      write_settling_setting('')
      count
    end
    return if claimed == ids.size

    raise Contested, "claim_corrections: reconciliation #{reconciliation.id} locked #{ids.size} " \
                     "#{'correction'.pluralize(ids.size)} but claimed #{claimed} — a concurrent reconciliation " \
                     'claimed the rest first. Rolling back to avoid carrying a correction twice.'
  end

  # The fingerprint of what this settlement wrote, against the one the
  # caller's preview had (Settlement.fingerprint).
  sig { params(fingerprint: String, balances: T::Hash[Integer, BigDecimal]).void }
  def refuse_what_the_preview_did_not_show!(fingerprint, balances)
    written = Settlement.fingerprint(cutoff: T.must(reconciliation.end_date), meal_ids: claimed_meals.map(&:first),
                                     correction_ids: claimed_corrections, balances: balances)
    return if written == fingerprint

    raise Changed, 'The dinners or amounts changed after the preview was made, so nothing was settled.'
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
  #
  # The database refuses an insert into either table unless
  # SETTLING_SETTING names the reconciliation the row belongs to
  # (20261009120000). So the setting is on for exactly these writes: set
  # first, and turned off once both tables are written. The writes run in their own savepoint
  # (requires_new) so that an error rolls the setting back with the rows.
  # Without the savepoint, a caller that caught the error and kept its
  # transaction would also keep the setting, and could then add rows to
  # this reconciliation as if the settlement wrote them.
  #
  # Returns the balances it stored, for the fingerprint check in settle!.
  sig { params(units: T::Hash[Integer, Reconciliation::SavedUnit]).returns(T::Hash[Integer, BigDecimal]) }
  def write_ledger!(units: {})
    ledger = reconciliation.settlement_ledger

    Reconciliation.transaction(requires_new: true) do
      write_settling_setting(T.must(reconciliation.id).to_s)
      persist_charges!(ledger)
      balances = persist_balances!(ledger, units)
      write_settling_setting('')
      balances
    end
  end

  # set_config(name, value, true) does what SET LOCAL does: the value
  # lasts until the end of the transaction.
  sig { params(value: String).void }
  def write_settling_setting(value)
    write_setting(SETTLING_SETTING, value)
  end

  sig { params(name: String, value: String).void }
  def write_setting(name, value)
    Reconciliation.connection.execute(Reconciliation.sanitize_sql_array(['SELECT set_config(?, ?, true)', name, value]))
  end

  # One row per source row: one credit per bill, one debit per attendance,
  # one per guest. insert_all! rather than create! because these are
  # written in a batch and there is nothing per-row to validate that the
  # check constraints and MealLedger do not already guarantee — and a
  # settlement writes a few hundred of them.
  #
  # insert_all! and not insert_all: without the bang, a row that breaks a
  # unique index is skipped with no error (ON CONFLICT DO NOTHING). A line
  # already sitting on the meal would then stay in place of the real one.
  # If it had the same amount, the meal would still add up to zero, and the
  # nightly check would not see it either.
  sig { params(ledger: MealLedger).void }
  def persist_charges!(ledger)
    # insert_all! fills created_at and updated_at itself, and an empty
    # list is a no-op without a query.
    MealCharge.insert_all!(
      ledger.lines.map do |line|
        {
          meal_id: line.meal_id, resident_id: line.resident_id, kind: line.kind.to_s,
          amount: line.amount, multiplier: line.multiplier, unit_cost: line.unit_cost,
          bill_amount: line.bill_amount
        }
      end
    )
  end

  # The resident goes in as a record, not an id: create! checks that the
  # resident exists, and with the record in hand that check reads
  # nothing. By id it read one resident per balance. The records come
  # from their own query, not from community.residents: that association
  # lives on the shared Community.instance, and once loaded it would
  # answer every later read in the same request or task, new residents
  # left out.
  #
  # Each line saves the person's unit and whether they lived here, as they
  # are now, on the day of the settlement (ADR 0011 rule 7). `units`
  # overrides that for the people a settlement worked out again had lines
  # for (Reconciliation#saved_units), so they keep the unit they settled in.
  # Returns the balances it stored.
  sig do
    params(ledger: MealLedger, units: T::Hash[Integer, Reconciliation::SavedUnit])
      .returns(T::Hash[Integer, BigDecimal])
  end
  def persist_balances!(ledger, units)
    balances = reconciliation.settlement_balances(ledger).reject { |_, amount| amount.zero? }
    residents = Resident.where(id: balances.keys).index_by { |resident| T.must(resident.id) }
    saved = balances.keys.to_h do |resident_id|
      resident = residents.fetch(resident_id)
      [resident_id, units.fetch(resident_id) { [T.must(resident.unit_id), T.must(resident.active)] }]
    end
    # The units go in as records too, read in one query, for the same reason.
    unit_records = Unit.where(id: saved.values.map(&:first)).index_by { |unit| T.must(unit.id) }
    balances.each do |resident_id, amount|
      unit_id, lived_here = saved.fetch(resident_id)
      reconciliation.reconciliation_balances.create!(resident: residents.fetch(resident_id), amount: amount,
                                                     unit: unit_records.fetch(unit_id), lived_here: lived_here)
    end
    balances
  end
end

# frozen_string_literal: true

# Control A: does every settled balance still match the source data behind it?
#
# For each reconciliation, recompute the settlement from its own meals, bills,
# attendance and guests, and compare that to the amounts stored at settlement
# time. They must be identical. A difference means the source rows changed
# after the fact — through the repair bypass, through direct psql, or through
# a race the guards did not cover.
#
# This is a control, not a guard. A guard refuses a bad write; a control
# proves afterwards that the numbers still match. Both are needed, because
# a guard can only refuse what it knows to look at. Issue #43 was a race that
# every guard allowed, and this check would have found it in production
# instead of only in a test.
#
# == Two checks, which fail for different reasons
#
# 1. Recompute. Rebuild the settlement from source with MealLedger and compare
#    it to the stored balances. Catches source rows that changed after
#    settlement.
#
# 2. Line items against balances. The meal_charges rows written at settlement
#    must add up, per resident, to the stored balance — within one cent, which
#    is all largest-remainder allocation is allowed to move them — and must sum
#    to exactly zero overall. No arithmetic happens in Ruby here: both sides
#    are read and PostgreSQL does the sums.
#
# The second is the stronger one, and it is why line items exist. The
# recompute check uses MealLedger, which is what wrote the stored values, so
# the same mistake would be made twice and agree with itself. The line-item
# check compares two tables written by different code at settlement time,
# with nothing recomputed.
#
# Neither proves the arithmetic is right in the first place. That is the
# Resident#calc_balance oracle's job, compared in
# spec/tasks/billing_recalculate_correctness_spec.rb and
# spec/tasks/settlement_matches_running_balance_spec.rb.
#
# Reconciliations settled before meal_charges existed have no lines and get
# check 1 only. Inventing lines for them now would be recording today's
# belief as though it were what happened then.
#
# One consequence worth expecting: if the settlement arithmetic is ever
# changed on purpose, this check will disagree with every reconciliation
# settled before the change, every night, forever. That is the correct alarm —
# it means the past no longer reproduces — but it needs a deliberate answer
# rather than being switched off. See the "still open" note in
# docs/money-path-observability.md.
#
# == Reads
#
# Everything is read inside one SERIALIZABLE READ ONLY DEFERRABLE snapshot.
# Without it, a settlement committing halfway through would be compared
# against source rows read before it and source rows read after it, and the
# check would report a mismatch that never existed. The run record is written
# afterwards, because that transaction may not write.
class LedgerVerification
  # Raised when at least one reconciliation disagrees with its source data.
  # The run row is already written by the time this is raised.
  class MismatchError < StandardError
    attr_reader :run

    def initialize(run)
      @run = run
      super(LedgerVerification.summary_for(run))
    end
  end

  def self.call
    new.call
  end

  # One reconciliation can fail both checks, so the count is of findings, not
  # of reconciliations. Naming which reconciliations are involved matters more
  # than the count anyway — that is what someone acts on.
  def self.summary_for(run)
    ids = run.details.pluck('reconciliation_id').uniq.sort
    checks = run.details.pluck('check').uniq.sort.join(' and ')

    "Ledger check failed: #{run.mismatch_count} #{'finding'.pluralize(run.mismatch_count)} " \
      "(#{checks}) across #{ids.size} of #{run.reconciliations_checked} " \
      "#{'reconciliation'.pluralize(run.reconciliations_checked)} — #{ids.join(', ')}. " \
      'Settled balances were changed after settlement, or the source rows behind them were. ' \
      'See docs/runbooks/settled-data-repair.md.'
  end

  # Largest-remainder allocation moves a balance by at most one cent away from
  # its exact amount, so that is the whole tolerance the line-item check is
  # allowed. Anything further apart is a real disagreement.
  ROUNDING_TOLERANCE = BigDecimal('0.01')

  def call
    started_at = Time.current
    checked = 0
    mismatches = []

    begin
      SnapshotRead.call do
        Reconciliation.order(:id).each do |reconciliation|
          checked += 1
          mismatches.concat(checks_for(reconciliation))
        end
      end
    rescue StandardError => e
      record(started_at: started_at, checked: checked, mismatches: mismatches, error: e)
      raise
    end

    run = record(started_at: started_at, checked: checked, mismatches: mismatches, error: nil)
    log(run)
    raise MismatchError, run if run.failed?

    run
  end

  private

  # Two independent checks per reconciliation, and they fail for different
  # reasons, so both run and both are reported.
  def checks_for(reconciliation)
    [recompute_check(reconciliation), line_item_check(reconciliation)].compact
  end

  # Check one: recompute the settlement from source and compare. Catches
  # source rows that changed after settlement.
  #
  # Zero balances are not stored — a resident who owes and is owed nothing
  # gets no row — so the recomputed side drops them too before comparing.
  def recompute_check(reconciliation)
    stored = stored_balances(reconciliation)
    source = reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
    return nil if stored == source

    detail(reconciliation, 'recompute', differences_between(stored, source))
  end

  # Check two: the line items must add up to the balances. No arithmetic
  # happens here at all — both sides are read, and the sums are done by
  # PostgreSQL. That is what makes this check independent of the code that
  # wrote either table, and the reason it can catch a mistake the recompute
  # check cannot: the recompute uses MealLedger, which is what produced the
  # stored values in the first place.
  #
  # Skipped for reconciliations settled before meal_charges existed. They
  # have no lines, and inventing some now would be recording today's belief
  # as though it were what happened then. Those keep the recompute check.
  def line_item_check(reconciliation)
    charges = MealCharge.for_reconciliation(reconciliation)
    return nil unless charges.exists?

    stored = stored_balances(reconciliation)
    summed = charges.group(:resident_id).sum(:amount)

    differences = line_item_differences(stored, summed)
    total = summed.values.sum(BigDecimal('0'))
    differences << lines_do_not_balance(total) if total.abs > Reconciliation::ZERO_SUM_EPSILON
    return nil if differences.empty?

    detail(reconciliation, 'line_items', differences)
  end

  # The line items are full precision and the balances are rounded to cents,
  # so these two can never be compared for equality — only for being within
  # the one cent that largest-remainder allocation is allowed to move things.
  def line_item_differences(stored, summed)
    (stored.keys | summed.keys).sort.filter_map do |resident_id|
      stored_amount = stored[resident_id] || BigDecimal('0')
      summed_amount = summed[resident_id] || BigDecimal('0')
      next if (stored_amount - summed_amount).abs <= ROUNDING_TOLERANCE

      {
        resident_id: resident_id,
        stored: stored[resident_id]&.to_s('F'),
        source: summed[resident_id]&.to_s('F')
      }
    end
  end

  # Every settlement's lines must sum to zero, the same rule the database
  # already enforces on the balances — but to within Reconciliation's epsilon,
  # not exactly.
  #
  # The balances can be held to exactly zero because they are whole cents that
  # allocate_to_cents made add up. The lines cannot: they are full-precision
  # BigDecimal, and BigDecimal division carries finite precision, so a meal
  # split three ways leaves a tail thirty digits down. $100 across three
  # people sums to -0.000000000000000000000000000002, not 0. Demanding exact
  # zero here would report every ordinary meal as corrupt.
  #
  # Reported without a resident because it is a fact about the whole
  # reconciliation, not about one person.
  def lines_do_not_balance(total)
    { resident_id: nil, stored: nil, source: total.to_s('F') }
  end

  def stored_balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  def detail(reconciliation, check, differences)
    {
      reconciliation_id: reconciliation.id,
      date: reconciliation.date.to_s,
      check: check,
      differences: differences
    }
  end

  # Amounts become strings, never JSON numbers: JSON numbers are IEEE floats
  # and money never touches one. A resident missing from one side is reported
  # as absent rather than as zero, because those are different faults — one
  # is a wrong amount, the other is a row that should not be there or one
  # that vanished.
  def differences_between(stored, source)
    (stored.keys | source.keys).sort.filter_map do |resident_id|
      next if stored[resident_id] == source[resident_id]

      {
        resident_id: resident_id,
        stored: stored[resident_id]&.to_s('F'),
        source: source[resident_id]&.to_s('F')
      }
    end
  end

  def record(started_at:, checked:, mismatches:, error:)
    LedgerCheckRun.create!(
      started_at: started_at,
      finished_at: Time.current,
      reconciliations_checked: checked,
      mismatch_count: mismatches.size,
      details: mismatches,
      error: error && "#{error.class}: #{error.message}"
    )
  end

  def log(run)
    if run.passed?
      Rails.logger.info(
        "ledger:verify checked #{run.reconciliations_checked} " \
        "#{'reconciliation'.pluralize(run.reconciliations_checked)} in #{run.duration.round(2)}s — all match"
      )
    else
      Rails.logger.error(self.class.summary_for(run))
      run.details.each { |detail| Rails.logger.error("  #{detail.to_json}") }
    end
  end
end

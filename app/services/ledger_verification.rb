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
# proves afterwards that the numbers still tie out. Both are needed, because
# a guard can only refuse what it knows to look at. Issue #43 was a race that
# every guard allowed, and this check would have found it in production
# instead of only in a test.
#
# == What it can and cannot prove
#
# It recomputes with MealLedger, which is also what wrote the stored values.
# So it proves the stored balance still follows from the source rows, and it
# cannot prove the arithmetic itself is right — the same mistake would be
# made twice and agree with itself. What covers that is the Resident#calc_balance
# oracle, which is written separately and compared in
# spec/tasks/billing_recalculate_correctness_spec.rb and
# spec/tasks/settlement_matches_running_balance_spec.rb.
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

  def self.summary_for(run)
    reconciliation_ids = run.details.pluck('reconciliation_id').join(', ')

    "Ledger check failed: #{run.mismatch_count} of #{run.reconciliations_checked} " \
      "#{'reconciliation'.pluralize(run.reconciliations_checked)} no longer match their source data " \
      "(#{reconciliation_ids}). Settled balances were changed after settlement, or the source rows " \
      'behind them were. See docs/runbooks/settled-data-repair.md.'
  end

  def call
    started_at = Time.current
    checked = 0
    mismatches = []

    begin
      SnapshotRead.call do
        Reconciliation.order(:id).each do |reconciliation|
          checked += 1
          difference = compare(reconciliation)
          mismatches << difference if difference
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

  # Zero balances are not stored — a resident who owes and is owed nothing
  # gets no row — so the recomputed side drops them too before comparing.
  def compare(reconciliation)
    stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
    source = reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
    return nil if stored == source

    {
      reconciliation_id: reconciliation.id,
      date: reconciliation.date.to_s,
      differences: differences_between(stored, source)
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
        "#{'reconciliation'.pluralize(run.reconciliations_checked)} in #{run.duration.round(2)}s — all tie out"
      )
    else
      Rails.logger.error(self.class.summary_for(run))
      run.details.each { |detail| Rails.logger.error("  #{detail.to_json}") }
    end
  end
end

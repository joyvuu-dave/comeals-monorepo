# typed: strict
# frozen_string_literal: true

# Settlement#correct! and its steps, in a module of their own so that
# Settlement stays one class a reader can hold in mind (RuboCop's
# Metrics/ClassLength). Included only in Settlement: correct! writes the
# settled tables with Settlement's own write_ledger!, so the arithmetic
# and the settlement's database setting are the settlement's.
module SettlementCorrecting
  extend T::Sig
  extend T::Helpers

  requires_ancestor { Settlement }

  # Work a settled period out again from its meals' rows as they are now,
  # replace its line items and balances with the result, and record what
  # changed: a SettlementCorrection with the reason, a line for each
  # person whose balance changed (before and after), and a copy of every
  # line item it deleted.
  #
  # For a settlement whose rows were wrong, when the owner decides the
  # settlement must show the right numbers. The first case is migration
  # 20261010130000: 11 bills of settled meals were marked No cost and also
  # had an amount, so their cooks had been credited $0 for them (owner
  # decision, 2026-10-10). The caller fixes the rows in the block:
  #
  #   Settlement.new(reconciliation).correct!(reason: '...') { fix the rows }
  #
  # Before the block runs, correct! asks the nightly check about this
  # settlement (LedgerVerification#findings_for) and refuses, writing
  # nothing, if it already disagrees with its rows or its line items. A
  # correction works the settlement out again from all of its rows, so it
  # would fold such an earlier difference in under the caller's reason,
  # and the nightly check would stop reporting it. A caller that means to
  # fold one in says so: include_earlier_differences: true. The record
  # then keeps that the caller did, and what the check found, and the
  # admin settlement page shows both. Without a block, the rows must
  # already be fixed, so only that caller can work.
  #
  # The block must end normally or raise. One left by return, break or
  # throw raises FixLeftEarly instead (see run_fix), so its fix never
  # stays without the new numbers.
  #
  # It keeps the same reconciliation row, the same meals and the same
  # cutoff. Settling the period again would sweep a different set of
  # meals. The arithmetic is write_ledger!'s, the same as a new
  # settlement's, so the new numbers are exactly what a settlement of
  # those meals would store today. A person who ate at none of the fixed
  # meals can still move by one cent: the cents are shared out across the
  # whole settlement (allocate_to_cents), so a change anywhere can move
  # who gets a leftover cent. That cent is in the record too.
  #
  # A settlement made before line items existed (2026-08-02) gets them
  # here, written from the same ledger as its new balances, so
  # ledger:verify's second check covers it from then on.
  #
  # The settlement row is locked first, so two corrections of one
  # settlement run one after the other. The repair bypass is on for the
  # two deletes only, and goes back to what it was before. The record is
  # written under the settlement's own setting (SETTLING_SETTING), which
  # the database requires for an insert into the correction tables. Its
  # own savepoint (requires_new), as in write_ledger!: if any step fails,
  # none of its writes stay, the caller's fix included, even in a
  # transaction the caller keeps.
  sig do
    params(reason: String, include_earlier_differences: T::Boolean, fix: T.nilable(T.proc.void))
      .returns(SettlementCorrection)
  end
  def correct!(reason:, include_earlier_differences: false, &fix)
    Reconciliation.transaction(requires_new: true) do
      reconciliation.lock!
      refuse_a_marked_settlement!
      earlier = earlier_differences(reason, include_earlier_differences)
      run_fix(fix)
      before = stored_balances
      units = reconciliation.saved_units
      correction = keep_old_ledger!(reason, include_earlier_differences, earlier)
      clear_ledger!
      write_ledger!(units: units)
      record_lines!(correction, before, stored_balances)
      correction
    end
  end

  private

  # Once a line is marked Paid or Let go, people have paid from this
  # settlement, and its numbers stay what they were (ADR 0011 rules 6 and
  # 8). Checked after the settlement row is locked; a mark is added
  # without that lock, but a marked line cannot be deleted (the marks'
  # foreign key), so a mark made at the same moment stops the correction
  # anyway.
  sig { void }
  def refuse_a_marked_settlement!
    marked = SettlementLineMark.joins(:reconciliation_balance)
                               .where(reconciliation_balances: { reconciliation_id: reconciliation.id })
    return unless marked.exists?

    raise Settlement::Marked,
          "Refused: settlement #{reconciliation.id} has lines marked Paid or Let go, so people have paid " \
          'from it and its numbers stay what they were. Correct the dinner instead; the next settlement ' \
          'carries it (ADR 0011 rule 6). Nothing was written.'
  end

  # The settlement's balances as stored, by resident id.
  sig { returns(T::Hash[Integer, BigDecimal]) }
  def stored_balances
    ReconciliationBalance.where(reconciliation_id: reconciliation.id).pluck(:resident_id, :amount).to_h
  end

  # Delete the settlement's line items and balances, with the repair
  # bypass on for exactly these two statements. The triggers refuse both
  # deletes without it (docs/runbooks/settled-data-repair.md). Both tables
  # in one go: clearing one leaves the other describing something else.
  sig { void }
  def clear_ledger!
    connection = Reconciliation.connection
    was = connection.select_value("SELECT current_setting('comeals.allow_settled_writes', true)").to_s
    write_setting(Settlement::BYPASS_SETTING, 'on')
    MealCharge.for_reconciliation(reconciliation).delete_all
    ReconciliationBalance.where(reconciliation_id: reconciliation.id).delete_all
    write_setting(Settlement::BYPASS_SETTING, was)
  end

  # What the nightly check finds in this settlement now, before the
  # caller's fix: refused unless the caller let the correction fold it in.
  # See correct!.
  sig do
    params(reason: String, include_earlier_differences: T::Boolean).returns(T::Array[LedgerVerification::Detail])
  end
  def earlier_differences(reason, include_earlier_differences)
    findings = LedgerVerification.new.findings_for(reconciliation)
    return findings if findings.empty? || include_earlier_differences

    checks = findings.map { |finding| "#{finding.fetch(:check)} (#{finding.fetch(:differences).size} difference(s))" }
    raise Settlement::EarlierDifference,
          "Refused: settlement #{reconciliation.id} already disagrees with its rows, before this correction " \
          "changed anything (the nightly check finds: #{checks.join(', ')}). A correction would fold that in " \
          "under the reason \"#{reason}\", and the nightly check would stop reporting it. Find out where it " \
          'came from first (docs/runbooks/settled-data-repair.md). Nothing was written.'
  end

  # Run the caller's fix, and refuse a block that was left by return,
  # break or throw: Rails would commit the savepoint around it with the fix
  # in and no correction (FixLeftEarly). Raising from the ensure replaces
  # the jump with the error, so the savepoint rolls back.
  sig { params(fix: T.nilable(T.proc.void)).void }
  def run_fix(fix)
    return if fix.nil?

    ended = T.let(false, T::Boolean)
    begin
      fix.call
      ended = true
    rescue Exception # rubocop:disable Lint/RescueException -- only notes that the block ended by raising; raises it again unchanged
      ended = true
      raise
    ensure
      # T.unsafe: Sorbet does not see that return, break or throw can
      # leave the block before `ended` is set, and calls this dead code.
      unless T.unsafe(ended)
        raise Settlement::FixLeftEarly,
              'The fix block was left by return, break or throw. Nothing was written: the fix and the ' \
              'correction stay together or not at all.'
      end
    end
  end

  # Start the record: the correction row, then a copy of every line item
  # the correction is about to delete, column for column, in one
  # statement.
  sig do
    params(reason: String, include_earlier_differences: T::Boolean,
           earlier: T::Array[LedgerVerification::Detail]).returns(SettlementCorrection)
  end
  def keep_old_ledger!(reason, include_earlier_differences, earlier)
    write_settling_setting(T.must(reconciliation.id).to_s)
    correction = reconciliation.settlement_corrections.create!(
      reason: reason, include_earlier_differences: include_earlier_differences, earlier_differences: earlier
    )
    binds = { correction: correction.id, at: correction.created_at, reconciliation: reconciliation.id }
    Reconciliation.connection.execute(Reconciliation.sanitize_sql_array([<<~SQL.squish, binds]))
      INSERT INTO settlement_correction_charges
        (settlement_correction_id, meal_charge_id, meal_id, resident_id, kind, amount, multiplier, unit_cost,
         bill_amount, charged_at, created_at, updated_at)
      SELECT :correction, meal_charges.id, meal_charges.meal_id, meal_charges.resident_id, meal_charges.kind,
             meal_charges.amount, meal_charges.multiplier, meal_charges.unit_cost, meal_charges.bill_amount,
             meal_charges.created_at, :at, :at
      FROM meal_charges JOIN meals ON meals.id = meal_charges.meal_id
      WHERE meals.reconciliation_id = :reconciliation
      ORDER BY meal_charges.id
    SQL
    write_settling_setting('')
    correction
  end

  # A correction line for each person whose balance changed. A person with
  # no balance on one side counts as zero there, the way the balances
  # table leaves zero out. insert_all! because the database checks every
  # rule the model has (NOT NULL, the foreign keys, the unique index, the
  # changed CHECK), and through the model each line would read its
  # resident and look for a duplicate first.
  sig do
    params(correction: SettlementCorrection, before: T::Hash[Integer, BigDecimal],
           after: T::Hash[Integer, BigDecimal]).void
  end
  def record_lines!(correction, before, after)
    zero = BigDecimal('0')
    lines = (before.keys | after.keys).sort.filter_map do |resident_id|
      old_amount = before.fetch(resident_id, zero)
      new_amount = after.fetch(resident_id, zero)
      next if old_amount == new_amount

      { settlement_correction_id: correction.id, resident_id: resident_id, old_amount: old_amount,
        new_amount: new_amount }
    end
    return if lines.empty?

    write_settling_setting(T.must(reconciliation.id).to_s)
    SettlementCorrectionLine.insert_all!(lines)
    write_settling_setting('')
  end
end

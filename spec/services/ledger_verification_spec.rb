# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LedgerVerification do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

  # A settled reconciliation: the cook is owed $40, the eater owes $40.
  def settle
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)

    settle!(cutoff: Date.yesterday)
  end

  # Settled data is immutable by design, so the only way to set up the thing
  # this check exists to find is to go behind the guards on purpose — which
  # is exactly what a person with psql access can do, and what the repair
  # bypass is for.
  def behind_the_guards
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      yield
    end
  end

  describe 'a ledger where everything matches' do
    it 'passes and records the run' do
      settle

      run = described_class.call

      expect(run).to be_passed
      expect(run.reconciliations_checked).to eq(1)
      expect(run.mismatch_count).to eq(0)
      expect(run.details).to eq([])
      expect(run.error).to be_nil
    end

    # The whole reason the table exists. A check that only writes on failure
    # cannot tell a quiet night from a night the job never ran.
    it 'leaves a dated record even though nothing was wrong' do
      settle

      expect { described_class.call }.to change(LedgerCheckRun, :count).by(1)

      run = LedgerCheckRun.recent.first
      expect(run.started_at).to be_present
      expect(run.finished_at).to be >= run.started_at
    end

    it 'passes when there is nothing settled yet' do
      run = described_class.call

      expect(run).to be_passed
      expect(run.reconciliations_checked).to eq(0)
    end

    it 'checks every reconciliation, not only the most recent' do
      settle
      settle

      expect(described_class.call.reconciliations_checked).to eq(2)
    end
  end

  describe 'a stored balance that was changed after settlement' do
    # Moving a dollar from one resident to another keeps the reconciliation
    # summing to zero, so the database guards are all satisfied. Nothing
    # except this check can see it.
    it 'is found, and the run says which reconciliation and which residents' do
      reconciliation = settle
      cook_balance = reconciliation.reconciliation_balances.find_by(resident: cook)
      eater_balance = reconciliation.reconciliation_balances.find_by(resident: eater)

      behind_the_guards do
        ReconciliationBalance.where(id: cook_balance.id).update_all(amount: BigDecimal('39'))
        ReconciliationBalance.where(id: eater_balance.id).update_all(amount: BigDecimal('-39'))
      end

      expect { described_class.call }.to raise_error(described_class::MismatchError)

      run = LedgerCheckRun.recent.first
      expect(run).to be_failed

      # Both checks catch this one, for different reasons: the recompute says
      # the balance no longer follows from the source rows, and the line items
      # say it no longer matches what they add up to.
      expect(run.details.pluck('check')).to contain_exactly('recompute', 'line_items')
      expect(run.mismatch_count).to eq(2)

      detail = run.details.find { |d| d['check'] == 'recompute' }
      expect(detail['reconciliation_id']).to eq(reconciliation.id)
      expect(detail['differences'].pluck('resident_id')).to contain_exactly(cook.id, eater.id)
    end

    it 'records amounts as strings, never as JSON floats' do
      reconciliation = settle
      cook_balance = reconciliation.reconciliation_balances.find_by(resident: cook)
      eater_balance = reconciliation.reconciliation_balances.find_by(resident: eater)

      behind_the_guards do
        ReconciliationBalance.where(id: cook_balance.id).update_all(amount: BigDecimal('39'))
        ReconciliationBalance.where(id: eater_balance.id).update_all(amount: BigDecimal('-39'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      difference = LedgerCheckRun.recent.first.details.first['differences'].first
      expect(difference['stored']).to be_a(String)
      expect(difference['source']).to be_a(String)
      expect(BigDecimal(difference['source'])).to eq(BigDecimal('40'))
    end

    it 'names the reconciliation in the error a human will read' do
      reconciliation = settle
      cook_balance = reconciliation.reconciliation_balances.find_by(resident: cook)
      eater_balance = reconciliation.reconciliation_balances.find_by(resident: eater)

      behind_the_guards do
        ReconciliationBalance.where(id: cook_balance.id).update_all(amount: BigDecimal('39'))
        ReconciliationBalance.where(id: eater_balance.id).update_all(amount: BigDecimal('-39'))
      end

      expect { described_class.call }
        .to raise_error(described_class::MismatchError, /1 of 1 reconciliation.*#{reconciliation.id}/m)
    end

    # A third eater's balance is left alone, so a finding that listed
    # every resident, and not only the ones whose amounts differ, fails.
    it 'lists only the residents whose balance differs' do
      other = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Other')
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('90'))
      [cook, eater, other].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
      reconciliation = settle!(cutoff: Date.yesterday)
      behind_the_guards do
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: cook.id)
                             .update_all(amount: BigDecimal('61'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: eater.id)
                             .update_all(amount: BigDecimal('-31'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      detail = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'recompute' }
      expect(detail['differences']).to eq([
                                            { 'resident_id' => cook.id, 'stored' => '61.0', 'source' => '60.0' },
                                            { 'resident_id' => eater.id, 'stored' => '-31.0', 'source' => '-30.0' }
                                          ])
    end
  end

  describe 'source data that was changed after settlement' do
    # This is the shape of issue #43: a row removed from a meal a
    # reconciliation already counted, leaving a settled balance with nothing
    # behind it. Every guard allows it, because the guards were bypassed.
    it 'is found when attendance is deleted behind the guards' do
      reconciliation = settle
      attendance = MealResident.find_by(resident: eater)

      behind_the_guards { MealResident.where(id: attendance.id).delete_all }

      expect { described_class.call }.to raise_error(described_class::MismatchError)
      expect(LedgerCheckRun.recent.first.details.first['reconciliation_id']).to eq(reconciliation.id)
    end

    it 'is found when a settled bill amount is rewritten behind the guards' do
      settle
      bill = Bill.find_by(resident: cook)

      behind_the_guards { Bill.where(id: bill.id).update_all(amount: BigDecimal('100')) }

      expect { described_class.call }.to raise_error(described_class::MismatchError)
    end

    # A resident who should have no row at all is a different fault from one
    # whose amount is wrong, and the record says which it was.
    it 'reports a resident present on one side only as absent, not as zero' do
      reconciliation = settle
      attendance = MealResident.find_by(resident: eater)

      behind_the_guards { MealResident.where(id: attendance.id).delete_all }

      suppress(described_class::MismatchError) { described_class.call }

      differences = LedgerCheckRun.recent.first.details.first['differences']
      eater_difference = differences.find { |d| d['resident_id'] == eater.id }

      expect(reconciliation.reconciliation_balances.find_by(resident: eater)).to be_present
      expect(eater_difference['stored']).to eq('-40.0')
      expect(eater_difference['source']).to be_nil
    end
  end

  describe 'a stored balance row that is gone' do
    it 'reports the resident as absent on the stored side, not as zero' do
      reconciliation = settle
      row = reconciliation.reconciliation_balances.find_by(resident: eater)

      behind_the_guards { ReconciliationBalance.where(id: row.id).delete_all }

      suppress(described_class::MismatchError) { described_class.call }

      details = LedgerCheckRun.recent.first.details
      recompute = details.find { |d| d['check'] == 'recompute' }
      eater_difference = recompute['differences'].find { |d| d['resident_id'] == eater.id }
      expect(eater_difference['stored']).to be_nil
      expect(eater_difference['source']).to eq('-40.0')
    end
  end

  describe 'line items that no longer add up to the balances' do
    it 'reports a resident with a balance but no lines, and one with lines but no balance, as absent' do
      reconciliation = settle
      row = reconciliation.reconciliation_balances.find_by(resident: cook)

      behind_the_guards do
        MealCharge.where(resident_id: eater.id).delete_all
        ReconciliationBalance.where(id: row.id).delete_all
      end

      suppress(described_class::MismatchError) { described_class.call }

      lines = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'line_items' }
      by_resident = lines['differences'].index_by { |d| d['resident_id'] }
      expect(by_resident[eater.id]['source']).to be_nil
      expect(by_resident[eater.id]['stored']).to eq('-40.0')
      expect(by_resident[cook.id]['stored']).to be_nil
      expect(by_resident[cook.id]['source']).to eq('40.0')
    end

    # The case that only exists because line items exist. Nothing about the
    # source rows or the balances changed, so the recompute check is happy —
    # it never looks at meal_charges. Only comparing the two stored tables
    # against each other can see this.
    it 'is found when a line item is rewritten and nothing else is' do
      settle
      charge = MealCharge.where(kind: 'credit').first

      behind_the_guards do
        MealCharge.where(id: charge.id).update_all(amount: charge.amount - BigDecimal('5'))
      end

      expect { described_class.call }.to raise_error(described_class::MismatchError)

      details = LedgerCheckRun.recent.first.details
      expect(details.pluck('check')).to eq(['line_items'])
    end

    it 'is found when a line item is deleted' do
      settle
      charge = MealCharge.where(kind: %w[debit guest_debit]).first

      behind_the_guards { MealCharge.where(id: charge.id).delete_all }

      expect { described_class.call }.to raise_error(described_class::MismatchError)
      expect(LedgerCheckRun.recent.first.details.pluck('check')).to eq(['line_items'])
    end

    # A resident's stored balance is rounded to cents and their lines are not,
    # so the two are often not equal. Rounding leaves them less than one cent
    # apart, so the check allows any gap under one cent and nothing more.
    # Allowing less would report correct ledgers every night; allowing more
    # would miss real edits.
    it 'does not complain about ordinary cent rounding' do
      eaters = [eater] + %w[Second Third].map do |name|
        create(:resident, community: community, unit: unit, multiplier: 2, name: name)
      end
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('100'))
      eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
      settle!(cutoff: Date.yesterday)

      # The cook does not eat. $100 across three eaters: one owes 33.33333334
      # and two owe 33.33333333. Cut toward zero to cents, the balances are
      # +100.00 and three -33.33, which sum to +0.01, so allocation must move
      # one cent: the eater who lost the most gets -33.34. That balance is
      # 0.00666666 from its lines, and the check must allow it. This example
      # is worthless if no cent moved.
      sums = MealCharge.group(:resident_id).sum(:amount)
      stored = ReconciliationBalance.pluck(:resident_id, :amount).to_h
      expect(stored.values.sort).to eq([BigDecimal('-33.34'), BigDecimal('-33.33'), BigDecimal('-33.33'),
                                        BigDecimal('100')])
      moved = stored.key(BigDecimal('-33.34'))
      expect(sums[moved]).to eq(BigDecimal('-33.33333334'))

      expect(described_class.call).to be_passed
    end

    it 'skips reconciliations settled before line items existed' do
      reconciliation = settle

      behind_the_guards { MealCharge.for_reconciliation(reconciliation).delete_all }

      # No lines at all is not a mismatch — it is a settlement from before
      # this table existed, and the recompute check still covers it.
      expect(described_class.call).to be_passed
    end
  end

  describe 'what the run says' do
    it 'names every reconciliation and every check in the summary, in order, and hands the run to the error' do
      first = settle
      second = settle
      behind_the_guards do
        balances = ReconciliationBalance.where(reconciliation: [first, second])
        balances.where(resident: cook).update_all(amount: BigDecimal('39'))
        balances.where(resident: eater).update_all(amount: BigDecimal('-39'))
      end

      expect { described_class.call }.to raise_error(described_class::MismatchError) do |error|
        run = LedgerCheckRun.recent.first
        expect(error.run).to eq(run)
        expect(error.message).to eq(
          'Ledger check failed: 4 findings (line_items and recompute) across 2 of 2 reconciliations — ' \
          "#{first.id}, #{second.id}. Settled balances were changed after settlement, or the source rows " \
          'behind them were. See docs/runbooks/settled-data-repair.md.'
        )
        expect(run.details.pluck('reconciliation_id')).to eq([first.id, first.id, second.id, second.id])
      end
    end

    it 'dates each finding and writes the amounts as plain decimals, lowest resident id first' do
      reconciliation = settle
      behind_the_guards do
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: cook.id)
                             .update_all(amount: BigDecimal('39.5'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: eater.id)
                             .update_all(amount: BigDecimal('-39.5'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      detail = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'recompute' }
      expect(detail['date']).to eq(reconciliation.date.iso8601)
      expect(detail['differences']).to eq([
                                            { 'resident_id' => cook.id, 'stored' => '39.5', 'source' => '40.0' },
                                            { 'resident_id' => eater.id, 'stored' => '-39.5', 'source' => '-40.0' }
                                          ])
    end

    it 'reports lines that sum below zero the same as lines that sum above it' do
      reconciliation = settle
      behind_the_guards do
        # 79.5 in, 80 charged out: the lines sum to -0.5. The balances are
        # moved with them, so only the sum is wrong.
        MealCharge.where(meal_id: reconciliation.meals.select(:id), resident_id: cook.id, kind: 'credit')
                  .update_all(amount: BigDecimal('79.5'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: cook.id)
                             .update_all(amount: BigDecimal('39.5'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      detail = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'line_items' }
      expect(detail['differences']).to include('resident_id' => nil, 'stored' => nil, 'source' => '-0.5')
    end

    # Rounding to cents moves a cent only to a balance whose lines left a
    # remainder (Settlement.allocate_to_cents), so a stored balance is
    # always less than one cent from its lines. A gap of exactly one cent
    # can only come from an edit. Here a cent is moved between two lines
    # with the repair bypass on: the lines still sum to zero, and the
    # source rows did not change, so only this comparison can see it.
    it 'reports a line sum exactly one cent from the balance, which rounding to cents can never produce' do
      reconciliation = settle
      behind_the_guards do
        MealCharge.where(meal_id: reconciliation.meals.select(:id), resident_id: cook.id, kind: 'credit')
                  .update_all(amount: BigDecimal('80.01'))
        MealCharge.where(meal_id: reconciliation.meals.select(:id), resident_id: eater.id, kind: 'debit')
                  .update_all(amount: BigDecimal('-40.01'))
      end

      expect { described_class.call }.to raise_error(described_class::MismatchError)

      details = LedgerCheckRun.recent.first.details
      expect(details.pluck('check')).to eq(['line_items'])
      expect(details.first['differences']).to eq([
                                                   { 'resident_id' => cook.id, 'stored' => '40.0',
                                                     'source' => '40.01' },
                                                   { 'resident_id' => eater.id, 'stored' => '-40.0',
                                                     'source' => '-40.01' }
                                                 ])
    end

    it 'reports line items that no longer sum to zero as a finding with no resident' do
      reconciliation = settle
      behind_the_guards do
        # The cook's credit for the receipt, not the debit for eating. 80.5
        # in, 80 charged out: the lines sum to 0.5.
        MealCharge.where(meal_id: reconciliation.meals.select(:id), resident_id: cook.id, kind: 'credit')
                  .update_all(amount: BigDecimal('80.5'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: cook.id)
                             .update_all(amount: BigDecimal('40.5'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: eater.id)
                             .update_all(amount: BigDecimal('-40.5'))
      end

      suppress(described_class::MismatchError) { described_class.call }

      detail = LedgerCheckRun.recent.first.details.find { |d| d['check'] == 'line_items' }
      expect(detail['differences']).to include('resident_id' => nil, 'stored' => nil, 'source' => '0.5')
    end

    it 'logs a failed run at error level with the summary' do
      reconciliation = settle
      behind_the_guards do
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: cook.id)
                             .update_all(amount: BigDecimal('39'))
        ReconciliationBalance.where(reconciliation_id: reconciliation.id, resident_id: eater.id)
                             .update_all(amount: BigDecimal('-39'))
      end
      allow(Rails.logger).to receive(:error)

      suppress(described_class::MismatchError) { described_class.call }

      expect(Rails.logger).to have_received(:error).with(/Ledger check failed: 2 findings/)
    end
  end

  describe 'a run that cannot finish' do
    it 'records what went wrong, by class and message' do
      settle
      allow(Reconciliation).to receive(:order).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

      suppress(ActiveRecord::StatementInvalid) { described_class.call }

      expect(LedgerCheckRun.recent.first.error).to eq('ActiveRecord::StatementInvalid: connection lost')
    end

    # Nothing was found before the crash, so the crash itself is what is
    # raised, and nothing is logged as a failed check.
    it 'records the error and re-raises, so the failure is never silent' do
      settle
      allow_any_instance_of(Reconciliation).to receive(:settlement_balances) # rubocop:disable RSpec/AnyInstance -- the failure has to come from inside the loop
        .and_raise(ActiveRecord::StatementInvalid, 'connection lost')
      allow(Rails.logger).to receive(:error)

      expect { described_class.call }.to raise_error(ActiveRecord::StatementInvalid)

      run = LedgerCheckRun.recent.first
      expect(run).to be_errored
      expect(run).not_to be_passed
      expect(run).not_to be_failed
      expect(run.error).to include('connection lost')
      expect(Rails.logger).not_to have_received(:error)
    end
  end

  # A difference found before a crash is a fact about the books. The run
  # says it failed, and the error names the difference first, with the
  # crash as its cause, so the alert does not hide it behind a lost
  # connection.
  describe 'a run that finds a difference and then cannot finish' do
    # The first reconciliation's balances were edited; checking the second
    # one crashes. Fresh rows, so the stubs below touch only these objects.
    def edit_the_first_and_crash_on_the_second
      first = settle
      second = settle
      behind_the_guards do
        balances = ReconciliationBalance.where(reconciliation: first)
        balances.where(resident: cook).update_all(amount: BigDecimal('39'))
        balances.where(resident: eater).update_all(amount: BigDecimal('-39'))
      end
      crashing = Reconciliation.find(second.id)
      allow(crashing).to receive(:settlement_balances).and_raise(ActiveRecord::StatementInvalid, 'connection lost')
      allow(Reconciliation).to receive(:order).with(:id).and_return([Reconciliation.find(first.id), crashing])
      first
    end

    it 'records a failed run that did not finish, with what it found' do
      first = edit_the_first_and_crash_on_the_second

      suppress(described_class::MismatchError) { described_class.call }

      run = LedgerCheckRun.recent.first
      expect(run).to be_failed
      expect(run).to be_errored
      expect(run.error).to eq('ActiveRecord::StatementInvalid: connection lost')
      expect(run.details.pluck('reconciliation_id', 'check'))
        .to eq([[first.id, 'recompute'], [first.id, 'line_items']])
    end

    it 'raises the difference, with the crash as its cause' do
      first = edit_the_first_and_crash_on_the_second

      expect { described_class.call }.to raise_error(described_class::MismatchError) do |error|
        expect(error.run).to eq(LedgerCheckRun.recent.first)
        expect(error.message).to eq(
          'Ledger check failed: 2 findings (line_items and recompute) across 1 of 2 reconciliations — ' \
          "#{first.id}. Settled balances were changed after settlement, or the source rows behind them " \
          'were. See docs/runbooks/settled-data-repair.md. The check did not finish, so it may have ' \
          'missed more: ActiveRecord::StatementInvalid: connection lost'
        )
        expect(error.cause).to be_a(ActiveRecord::StatementInvalid)
        expect(error.cause.message).to eq('connection lost')
      end
    end

    # The crash here was a lost connection, so saving the run can fail too.
    # Then the log is the only place the difference is written down.
    it 'logs what it found before saving the run, so a failed save does not lose it' do
      first = edit_the_first_and_crash_on_the_second
      allow(LedgerCheckRun).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do |run|
          allow(run).to receive(:save!).and_raise(ActiveRecord::ConnectionNotEstablished, 'still gone')
        end
      end
      allow(Rails.logger).to receive(:error)

      expect { described_class.call }.to raise_error(ActiveRecord::ConnectionNotEstablished, 'still gone')

      expect(Rails.logger).to have_received(:error)
        .with(/\ALedger check failed: 2 findings .* — #{first.id}\. .* did not finish/)
      expect(Rails.logger).to have_received(:error).with(/"reconciliation_id":#{first.id},/).twice
    end

    # If both checks of a reconciliation had to finish before either
    # finding was kept, a crash in the second check would lose the first
    # check's finding.
    it 'keeps a finding from the first check when the second check of the same reconciliation crashes' do
      reconciliation = settle
      behind_the_guards do
        balances = ReconciliationBalance.where(reconciliation: reconciliation)
        balances.where(resident: cook).update_all(amount: BigDecimal('39'))
        balances.where(resident: eater).update_all(amount: BigDecimal('-39'))
      end
      allow(MealCharge).to receive(:for_reconciliation).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

      expect { described_class.call }.to raise_error(described_class::MismatchError)

      run = LedgerCheckRun.recent.first
      expect(run).to be_errored
      expect(run.mismatch_count).to eq(1)
      expect(run.details.pluck('reconciliation_id', 'check')).to eq([[reconciliation.id, 'recompute']])
    end
  end

  # The check reads a reconciliation's balances and its lines in separate
  # queries. A repair rewrites both in one transaction, so if one committed
  # between two of those reads, a correct ledger could look wrong. So the
  # whole check reads from one snapshot. now() is the time its transaction
  # started, so one value for every reconciliation means one transaction.
  # The group commits for real: inside the test transaction, the snapshot
  # would be a savepoint and prove nothing.
  describe 'the snapshot it reads from' do
    include_context 'with no test transaction'

    it 'reads every reconciliation in one read-only transaction' do
      settle
      settle
      seen = []
      allow(MealCharge).to receive(:for_reconciliation).and_wrap_original do |original, reconciliation|
        seen << ActiveRecord::Base.connection.select_rows(
          "SELECT now()::text, current_setting('transaction_read_only')"
        ).first
        original.call(reconciliation)
      end

      expect(described_class.call).to be_passed

      expect(seen.size).to eq(2)
      expect(seen.uniq.size).to eq(1)
      expect(seen.first.last).to eq('on')
    end
  end
end

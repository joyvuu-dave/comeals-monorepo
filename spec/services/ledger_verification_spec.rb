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
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    Reconciliation.create!(community: community, end_date: Date.yesterday)
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

  describe 'line items that no longer add up to the balances' do
    # The case that only exists because line items exist. Nothing about the
    # source rows or the balances changed, so the recompute check is happy —
    # it never looks at meal_charges. Only comparing the two stored tables
    # against each other can see this.
    it 'is found when a line item is rewritten and nothing else is' do
      settle
      charge = MealCharge.credits.first

      behind_the_guards do
        MealCharge.where(id: charge.id).update_all(amount: charge.amount - BigDecimal('5'))
      end

      expect { described_class.call }.to raise_error(described_class::MismatchError)

      details = LedgerCheckRun.recent.first.details
      expect(details.pluck('check')).to eq(['line_items'])
    end

    it 'is found when a line item is deleted' do
      settle
      charge = MealCharge.debits.first

      behind_the_guards { MealCharge.where(id: charge.id).delete_all }

      expect { described_class.call }.to raise_error(described_class::MismatchError)
      expect(LedgerCheckRun.recent.first.details.pluck('check')).to eq(['line_items'])
    end

    # A resident's stored balance is rounded to cents and their lines are not,
    # so the two are never equal. The check has to allow exactly the one cent
    # that largest-remainder allocation is allowed to move a balance, and no
    # more — otherwise it would either cry wolf every night or miss real drift.
    it 'does not complain about ordinary cent rounding' do
      cook_c = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Third')
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('100'))
      [cook, eater, cook_c].each do |person|
        create(:meal_resident, meal: meal, resident: person, community: community, multiplier: 2)
      end
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      # 100 split three ways does not divide evenly, so allocation really did
      # move pennies here — this example is worthless if it did not.
      sums = MealCharge.group(:resident_id).sum(:amount)
      stored = ReconciliationBalance.pluck(:resident_id, :amount).to_h
      expect(stored.any? { |id, amount| amount != sums[id] }).to be(true)

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

  describe 'a run that cannot finish' do
    it 'records the error and re-raises, so the failure is never silent' do
      settle
      allow_any_instance_of(Reconciliation).to receive(:settlement_balances) # rubocop:disable RSpec/AnyInstance -- the failure has to come from inside the loop
        .and_raise(ActiveRecord::StatementInvalid, 'connection lost')

      expect { described_class.call }.to raise_error(ActiveRecord::StatementInvalid)

      run = LedgerCheckRun.recent.first
      expect(run).to be_errored
      expect(run).not_to be_passed
      expect(run.error).to include('connection lost')
    end
  end
end

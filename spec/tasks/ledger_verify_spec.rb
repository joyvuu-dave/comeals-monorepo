# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The task is a thin wrapper: LedgerVerification does the work and is covered
# in spec/services/ledger_verification_spec.rb. What is only true here is the
# wiring — that the check runs, and that a night the books do not tie out
# reaches healthchecks.io instead of dying quietly in a dyno log.
RSpec.describe 'ledger:verify' do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  after do
    Rake::Task['ledger:verify'].reenable
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def settle(cook_name: 'Cook', eater_name: 'Eater')
    cook = create(:resident, community: community, unit: unit, multiplier: 2, name: cook_name)
    eater = create(:resident, community: community, unit: unit, multiplier: 2, name: eater_name)

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)

    settle!(cutoff: Date.yesterday)
  end

  it 'records which check run it made and how many reconciliations it looked at' do
    settle
    allow(Healthcheck).to receive(:ping)

    Rake::Task['ledger:verify'].invoke

    expect(JobRun.last.details)
      .to eq('ledger_check_run_id' => LedgerCheckRun.last.id, 'reconciliations_checked' => 1)
  end

  it 'reports a successful run to healthchecks' do
    settle
    allow(Healthcheck).to receive(:ping)

    Rake::Task['ledger:verify'].invoke

    expect(Healthcheck).to have_received(:ping).with('ledger-verify')
  end

  it 'records the run' do
    settle

    expect { Rake::Task['ledger:verify'].invoke }.to change(LedgerCheckRun, :count).by(1)
    expect(LedgerCheckRun.recent.first).to be_passed
  end

  it 'tells healthchecks the run failed when the books do not tie out' do
    reconciliation = settle
    balances = reconciliation.reconciliation_balances.order(:resident_id).to_a
    allow(Healthcheck).to receive(:ping)

    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      ReconciliationBalance.where(id: balances.first.id).update_all(amount: balances.first.amount + 1)
      ReconciliationBalance.where(id: balances.last.id).update_all(amount: balances.last.amount - 1)
    end

    expect { Rake::Task['ledger:verify'].invoke }.to raise_error(LedgerVerification::MismatchError)
    expect(Healthcheck).to have_received(:ping).with('ledger-verify', state: 'fail')
  end

  # The job's run record keeps only the error's own message, not its
  # cause. So when the check finds a difference and then crashes, the
  # error has to be the difference, and its message has to say the check
  # did not finish.
  it 'names the difference, not the crash, when the check finds one and then crashes' do
    reconciliation = settle
    balances = reconciliation.reconciliation_balances.order(:resident_id).to_a
    later = settle(cook_name: 'Second Cook', eater_name: 'Second Eater')
    allow(Healthcheck).to receive(:ping)
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      ReconciliationBalance.where(id: balances.first.id).update_all(amount: balances.first.amount + 1)
      ReconciliationBalance.where(id: balances.last.id).update_all(amount: balances.last.amount - 1)
    end
    crashing = Reconciliation.find(later.id)
    allow(crashing).to receive(:settlement_balances).and_raise(ActiveRecord::StatementInvalid, 'connection lost')
    allow(Reconciliation).to receive(:order).with(:id).and_return([Reconciliation.find(reconciliation.id), crashing])

    expect { Rake::Task['ledger:verify'].invoke }.to raise_error(LedgerVerification::MismatchError)

    expect(JobRun.last.error).to start_with('LedgerVerification::MismatchError: Ledger check failed: 2 findings')
    expect(JobRun.last.error).to include("— #{reconciliation.id}.")
    expect(JobRun.last.error).to end_with('did not finish, so it may have missed more: ' \
                                          'ActiveRecord::StatementInvalid: connection lost')
    expect(Healthcheck).to have_received(:ping).with('ledger-verify', state: 'fail')
  end
end

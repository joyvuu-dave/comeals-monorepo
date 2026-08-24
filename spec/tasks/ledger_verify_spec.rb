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

  def settle
    cook = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook')
    eater = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    settle!(community, cutoff: Date.yesterday)
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
end

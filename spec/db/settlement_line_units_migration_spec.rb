# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261010125950_save_each_persons_unit_on_a_settlement_line.rb')

# Migration 20261010125950 (ADR 0011 rule 7) fills in the unit and
# lived_here of the lines of every settlement made before it, from each
# person's unit and active flag when it runs, and records that day as
# the day the units were saved. Here it runs down and up again inside the
# example's transaction, which Postgres rolls back with the rest.
RSpec.describe 'migration 20261010125950, which saves each person\'s unit on a settlement line' do
  let(:community) { create(:community) }
  let(:elm) { create(:unit, community: community, name: 'Elm') }
  let(:oak) { create(:unit, community: community, name: 'Oak') }
  let(:cook) { create(:resident, community: community, unit: elm) }
  let(:eater) { create(:resident, community: community, unit: oak) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let!(:settled) do
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!(cutoff: latest)
  end

  # The settlement above queued deferred sum-zero checks in this example's
  # transaction, and Postgres refuses to ALTER a table with checks still
  # queued. A real migration starts with none queued and the check
  # deferred, so run the queued ones and defer it again. Left immediate,
  # it would hide a migration that queues checks of its own.
  def migrate(direction)
    connection = ActiveRecord::Base.connection
    connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
    connection.execute('SET CONSTRAINTS reconciliation_balances_sum_zero DEFERRED')
    $stdout = StringIO.new
    SaveEachPersonsUnitOnASettlementLine.new.migrate(direction)
  ensure
    $stdout = STDOUT
    [ReconciliationBalance, Reconciliation].each(&:reset_column_information)
  end

  it "fills in each person's unit and whether they live here as they are when it runs, and that day" do
    # A settlement made before the migration: its units were filled in later.
    settled.update_columns(units_recorded_on: settled.date + 1)
    migrate(:down)
    eater.update!(unit: elm, active: false)

    migrate(:up)

    expect(ReconciliationBalance.where(reconciliation_id: settled.id).pluck(:resident_id, :unit_id, :lived_here))
      .to contain_exactly([cook.id, elm.id, true], [eater.id, elm.id, false])
    expect(settled.reload.units_recorded_on).to eq(community.today)
    expect(ActiveRecord::Base.connection.select_value("SELECT current_setting('comeals.allow_settled_writes', true)"))
      .to eq('')
  end

  it 'refuses to roll back once a settlement saved its own units' do
    expect(settled.units_recorded_on).to eq(settled.date)

    expect { migrate(:down) }.to raise_error(StandardError, /1 settlement\(s\) saved each person's unit/)
    expect(ReconciliationBalance.column_names).to include('unit_id', 'lived_here')
  end
end

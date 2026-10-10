# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261010125800_create_settlement_corrections.rb')

# A settlement correction is kept as evidence of what a settlement said
# before and after. Rolling back migration 20261010125800 would drop the
# three tables, rows and all, while the balances and line items the
# corrections explain stay, and nothing would say where they came from.
# So down refuses while a correction is recorded. (Written by a review of
# 8a994760.)
RSpec.describe CreateSettlementCorrections do
  # A migration prints each statement it runs, so this sends that output
  # nowhere.
  def migrate_down
    $stdout = StringIO.new
    described_class.new.migrate(:down)
  ensure
    $stdout = STDOUT
  end

  it 'refuses to drop the record of a correction' do
    community = create(:community)
    cook = create(:resident, community: community)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: 30)
    create(:meal_resident, meal: meal, resident: create(:resident, community: community), community: community)
    reconciliation = settle!(cutoff: Date.new(2025, 3, 31))
    Settlement.new(reconciliation).correct!(reason: 'A receipt was wrong.')

    expect { migrate_down }.to raise_error(StandardError, /settlement_corrections holds 1 correction\(s\)/)
    expect(SettlementCorrection.count).to eq(1)
  end
end

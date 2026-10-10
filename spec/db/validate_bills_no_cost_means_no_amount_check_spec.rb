# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261010130200_validate_bills_no_cost_means_no_amount_check.rb')

# Step 3 of 3 (MODELS.md, Bill): check the rows already in the bills
# table against the CHECK bills_no_cost_means_no_amount. Step 1 added it
# NOT VALID, so it refused every new bill with both; step 2 turned No cost
# off on every bill that had both.
RSpec.describe ValidateBillsNoCostMeansNoAmountCheck do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community, date: Date.new(2024, 5, 18)) }

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
  ensure
    $stdout = STDOUT
  end

  def validated
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE conname = 'bills_no_cost_means_no_amount' AND conrelid = 'bills'::regclass
    SQL
  end

  # PostgreSQL cannot mark a CHECK as not validated again, so down drops
  # it and adds it back NOT VALID, the state after step 2.
  #
  # In a real run, up has a transaction of its own. Here it shares the
  # example's transaction with down, whose ALTER TABLE still holds a lock
  # that blocks writes, and strong_migrations refuses to validate under
  # that lock. safety_assured lets this one run through.
  it 'makes the CHECK NOT VALID on down, and validates it again on up' do
    migrate(:down)
    expect(validated).to be(false)

    migration.safety_assured { migrate(:up) }
    expect(validated).to be(true)
  end

  # Nothing in the app can write such a bill once step 1 has run, so this
  # needs a write that went around the CHECK. The check runs on its own,
  # the way the other validate migrations' specs run theirs.
  it 'refuses, naming each bill, when a bill has No cost and an amount' do
    migrate(:down)
    bill = no_cost_bill_with_an_amount(meal: meal, resident: create(:resident, community: community), amount: '86')

    expect { migration.suppress_messages { migration.send(:refuse_bills_with_both) } }.to raise_error(
      RuntimeError,
      "1 bill(s) have No cost and an amount: bill #{bill.id} (2024-05-18, $86.00). " \
      'Migration 20261010130000 turned No cost off on every such bill, and the CHECK refuses a new one, ' \
      'so a write went around the CHECK. Turn No cost off on each one, then run this migration again.'
    )
  end

  it 'passes when no bill has No cost and an amount' do
    create(:bill, meal: meal, community: community, amount: 0, no_cost: true)
    create(:bill, meal: meal, community: community, amount: BigDecimal('12'))

    expect { migration.suppress_messages { migration.send(:refuse_bills_with_both) } }.not_to raise_error
  end
end

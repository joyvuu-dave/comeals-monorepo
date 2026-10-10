# frozen_string_literal: true

require 'rails_helper'

# A bill marked No cost has no amount. The Bill model refuses both at once
# with a sentence (Bill::NO_COST_MEANS_NO_AMOUNT, spec/models/bill_spec.rb);
# this CHECK makes PostgreSQL refuse it from every write that skips the
# model (update_columns, update_all, a rake task, psql).
#
# Added NOT VALID (20261010125900), so it refused every new or changed
# row at once; then 20261010130000 turned No cost off on every bill that
# had both, and 20261010130200 validated it.
RSpec.describe 'bills no cost means no amount check constraint' do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:bill) { create(:bill, meal: meal, community: community, amount: BigDecimal('86')) }
  let(:connection) { ActiveRecord::Base.connection }

  it 'refuses a validation-skipping write that marks a bill with an amount No cost' do
    expect { bill.update_columns(no_cost: true) }
      .to raise_error(ActiveRecord::CheckViolation, /bills_no_cost_means_no_amount/)
  end

  it 'refuses a validation-skipping write that gives a no-cost bill an amount' do
    free = create(:bill, meal: meal, community: community, amount: 0, no_cost: true)

    expect { free.update_columns(amount: BigDecimal('0.01')) }
      .to raise_error(ActiveRecord::CheckViolation, /bills_no_cost_means_no_amount/)
  end

  it 'refuses an insert that skips the model' do
    cook = create(:resident, community: community)

    expect do
      Bill.insert!({ community_id: community.id, meal_id: meal.id, resident_id: cook.id,
                     amount: BigDecimal('5'), no_cost: true })
    end.to raise_error(ActiveRecord::CheckViolation, /bills_no_cost_means_no_amount/)
  end

  # Each write runs in its own savepoint: a refused statement ends the
  # transaction it runs in, and the example's transaction must go on.
  it 'takes No cost with $0 and an amount without No cost' do
    tries = [[0, true], [BigDecimal('86'), false], [0, false], [BigDecimal('0.01'), true]]
    accepted = tries.select do |amount, no_cost|
      Bill.transaction(requires_new: true) { bill.update_columns(amount: amount, no_cost: no_cost) }
    rescue ActiveRecord::CheckViolation
      false
    end

    expect(accepted).to eq([[0, true], [BigDecimal('86'), false], [0, false]])
  end

  it 'is validated, so every row in the table follows it' do
    validated = connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint WHERE conname = 'bills_no_cost_means_no_amount'
    SQL

    expect(validated).to be(true)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Pins issue #29: the bills_amount_whole_cents CHECK constraint makes
# PostgreSQL itself refuse a sub-cent bill amount. The SPA grammar, the API
# validation, and Bill's model validation are the first lines of defense;
# this constraint catches every write path that skips them (update_all,
# update_columns, raw SQL, a psql session).
RSpec.describe 'bills whole-cents check constraint' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  it 'refuses a raw insert with a sub-cent amount' do
    expect do
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO bills (amount, community_id, meal_id, resident_id, no_cost, created_at, updated_at)
        VALUES (12.345, #{community.id}, #{meal.id}, #{resident.id}, false, now(), now())
      SQL
    end.to raise_error(ActiveRecord::StatementInvalid, /bills_amount_whole_cents/)
  end

  it 'refuses a validation-skipping update' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

    expect do
      bill.update_columns(amount: BigDecimal('0.00000001'))
    end.to raise_error(ActiveRecord::StatementInvalid, /bills_amount_whole_cents/)
  end

  it 'allows whole-cent amounts' do
    expect do
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('12.34'))
    end.not_to raise_error
  end
end

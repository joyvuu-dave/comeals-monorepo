# frozen_string_literal: true

require 'rails_helper'

# Every write to a meal's rows takes the meal's lock first, in the same
# statement, from the model. The concurrency storm proved the deadlock
# this prevents (docs/concurrency-testing.md); this spec pins the
# statement itself, because a weaker lock, a missing ORDER BY, or a
# missing id would still pass every functional example.
RSpec.describe LocksItsMealFirst do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  # Each statement with the values bound to it, so the id list can be
  # checked in order.
  def statements_during(&)
    statements = []
    subscriber = lambda { |*, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      statements << [payload[:sql], payload[:type_casted_binds] || []]
    }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    statements
  end

  def lock_statement(*ids)
    list = ids.length == 1 ? '= $1' : "IN (#{ids.each_index.map { |i| "$#{i + 1}" }.join(', ')})"
    [%(SELECT "meals"."id" FROM "meals" WHERE "meals"."id" #{list} ORDER BY "meals"."id" ASC FOR KEY SHARE), ids]
  end

  def index_of_statement(statements, prefix)
    statements.index { |(sql, _binds)| sql.start_with?(prefix) }
  end

  it 'locks the meal, with FOR KEY SHARE, before a row is inserted' do
    statements = statements_during do
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    end

    lock = statements.index(lock_statement(meal.id))
    insert = index_of_statement(statements, 'INSERT INTO "bills"')
    expect(lock).not_to be_nil
    expect(insert).to be > lock
  end

  it 'locks the meal before a row is updated' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))

    statements = statements_during { bill.update!(amount: BigDecimal('12')) }

    lock = statements.index(lock_statement(meal.id))
    update = index_of_statement(statements, 'UPDATE "bills"')
    expect(lock).not_to be_nil
    expect(update).to be > lock
  end

  it 'locks the meal before a row is deleted' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))

    statements = statements_during { bill.destroy! }

    lock = statements.index(lock_statement(meal.id))
    delete = index_of_statement(statements, 'DELETE FROM "bills"')
    expect(lock).not_to be_nil
    expect(delete).to be > lock
  end

  it 'locks both meals, lowest id first, when a row moves to a meal with a lower id' do
    earlier = meal
    later = create(:meal, community: community, date: Date.new(2026, 4, 12))
    bill = create(:bill, meal: later, resident: cook, community: community, amount: BigDecimal('10'))
    expect(earlier.id).to be < later.id

    statements = statements_during { bill.update!(meal: earlier) }

    expect(statements).to include(lock_statement(earlier.id, later.id))
  end

  it 'locks both meals, lowest id first, when a row moves to a meal with a higher id' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    later = create(:meal, community: community, date: Date.new(2026, 4, 12))

    statements = statements_during { bill.update!(meal: later) }

    expect(statements).to include(lock_statement(meal.id, later.id))
  end

  it 'asks for the meal once when the row stays on it' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))

    statements = statements_during { bill.update!(amount: BigDecimal('12')) }

    expect(statements.count { |(sql, _binds)| sql.include?('FOR KEY SHARE') }).to eq(1)
    expect(statements).to include(lock_statement(meal.id))
  end
end

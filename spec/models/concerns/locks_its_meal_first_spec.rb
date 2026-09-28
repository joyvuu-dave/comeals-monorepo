# frozen_string_literal: true

require 'rails_helper'

# Every write to a meal's rows (a bill, an attendance row, a guest) takes
# the meal's lock first, in the same statement, from the model. The concurrency storm proved the deadlock
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

  # The same checks for every model that includes the concern. Each
  # context says how to make one of its rows on a meal, and gives one
  # change that keeps the row on its meal.
  shared_examples 'a row that locks its meal first' do |table|
    it 'locks the meal, with FOR KEY SHARE, before a row is inserted' do
      statements = statements_during { make_row(meal) }

      lock = statements.index(lock_statement(meal.id))
      insert = index_of_statement(statements, %(INSERT INTO "#{table}"))
      expect(lock).not_to be_nil
      expect(insert).to be > lock
    end

    it 'locks the meal before a row is updated' do
      row = make_row(meal)

      statements = statements_during { row.update!(change) }

      lock = statements.index(lock_statement(meal.id))
      update = index_of_statement(statements, %(UPDATE "#{table}"))
      expect(lock).not_to be_nil
      expect(update).to be > lock
    end

    it 'locks the meal before a row is deleted' do
      row = make_row(meal)

      statements = statements_during { row.destroy! }

      lock = statements.index(lock_statement(meal.id))
      delete = index_of_statement(statements, %(DELETE FROM "#{table}"))
      expect(lock).not_to be_nil
      expect(delete).to be > lock
    end

    it 'locks both meals, lowest id first, when a row moves to a meal with a lower id' do
      earlier = meal
      later = create(:meal, community: community, date: Date.new(2026, 4, 12))
      row = make_row(later)
      expect(earlier.id).to be < later.id

      statements = statements_during { row.update!(meal: earlier) }

      expect(statements).to include(lock_statement(earlier.id, later.id))
    end

    it 'locks both meals, lowest id first, when a row moves to a meal with a higher id' do
      row = make_row(meal)
      later = create(:meal, community: community, date: Date.new(2026, 4, 12))

      statements = statements_during { row.update!(meal: later) }

      expect(statements).to include(lock_statement(meal.id, later.id))
    end

    it 'asks for the meal once when the row stays on it' do
      row = make_row(meal)

      statements = statements_during { row.update!(change) }

      expect(statements.count { |(sql, _binds)| sql.include?('FOR KEY SHARE') }).to eq(1)
      expect(statements).to include(lock_statement(meal.id))
    end
  end

  context 'with a bill' do
    def make_row(on) = create(:bill, meal: on, resident: cook, community: community, amount: BigDecimal('10'))
    def change = { amount: BigDecimal('12') }

    it_behaves_like 'a row that locks its meal first', 'bills'
  end

  context 'with an attendance row' do
    def make_row(on) = create(:meal_resident, meal: on, resident: cook, community: community)
    def change = { late: true }

    it_behaves_like 'a row that locks its meal first', 'meal_residents'
  end

  context 'with a guest' do
    def make_row(on) = create(:guest, meal: on, resident: cook)
    def change = { vegetarian: true }

    it_behaves_like 'a row that locks its meal first', 'guests'
  end
end

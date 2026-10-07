# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261007153100_validate_meals_rotation_id_null_check.rb')

# The migration that makes meals.rotation_id NOT NULL refuses to run while
# a meal has no rotation, and names the meals by date. Without the guard
# the release would fail with a message about a constraint, and the
# person deploying would have to find the meals by hand.
RSpec.describe ValidateMealsRotationIdNullCheck do
  let(:community) { create(:community) }
  let(:connection) { ActiveRecord::Base.connection }

  # suppress_messages keeps the migration's "-- select_values ..." lines
  # out of the RSpec output.
  def refuse_meals_without_a_rotation!
    migration = described_class.new
    migration.suppress_messages { migration.send(:refuse_meals_without_a_rotation) }
  end

  it 'passes when every meal has a rotation' do
    create(:meal, community: community)

    expect { refuse_meals_without_a_rotation! }.not_to raise_error
  end

  it 'refuses, naming the dates, when meals have no rotation' do
    create(:meal, community: community, date: Date.new(2026, 5, 1))
    later = create(:meal, community: community, date: Date.new(2026, 5, 9))
    earlier = create(:meal, community: community, date: Date.new(2026, 4, 2))
    # NOT NULL forbids these rows, so drop it for this example (rolled
    # back with the transaction) and write them the way raw SQL would.
    connection.change_column_null(:meals, :rotation_id, true)
    connection.execute("UPDATE meals SET rotation_id = NULL WHERE id IN (#{later.id}, #{earlier.id})")

    expect { refuse_meals_without_a_rotation! }.to raise_error(
      RuntimeError,
      '2 meal(s) have no rotation: 2026-04-02, 2026-05-09. Give each one a rotation, then run this migration again.'
    )
  end
end

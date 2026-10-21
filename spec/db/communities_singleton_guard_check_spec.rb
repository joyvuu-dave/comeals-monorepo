# frozen_string_literal: true

require 'rails_helper'

# The app serves exactly one community. Community#enforce_singleton refuses
# a second one through the model, and the unique index on singleton_guard
# refuses a second row that has the same value. This CHECK makes the value
# always 0, so a write that skips the model (insert_all, a rake task, psql)
# cannot add a second community by giving it another value.
RSpec.describe 'communities singleton_guard check constraint' do
  let!(:community) { create(:community) }

  # Copies the one community's row, with a new name and the given
  # singleton_guard, in plain SQL so no model code runs.
  def insert_a_copy_with_guard(guard)
    copied = Community.column_names - %w[id name singleton_guard]
    columns = (copied + %w[name singleton_guard]).join(', ')
    Community.connection.execute(<<~SQL.squish)
      INSERT INTO communities (#{columns})
      SELECT #{copied.join(', ')}, 'A second community', #{Integer(guard)}
      FROM communities WHERE id = #{Integer(community.id)}
    SQL
  end

  it 'refuses a second community written past the model with another singleton_guard' do
    expect { insert_a_copy_with_guard(1) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_singleton_guard_is_zero/)
    expect(Community.count).to eq(1)
  end

  it 'refuses a second community written past the model with singleton_guard 0' do
    expect { insert_a_copy_with_guard(0) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end

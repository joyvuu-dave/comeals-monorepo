# frozen_string_literal: true

require 'rails_helper'

# bin/storm runs a real server against this worktree's test database, so
# its rows really commit, and its cleanup is what empties the database
# for the next RSpec run. It names a few tables and lets CASCADE follow
# the foreign keys from them. A table with no foreign key path from those
# is not emptied: request_keys (its sender is text) and audits stayed
# behind after a storm, and an example that counts every RequestKey then
# saw rows it did not make. rake test:storm empties the same way before
# a run.
#
# The check: every table the spec suite itself empties
# (NonTransactionalCleanup::TABLES) is named, or reached through foreign
# keys from a named one.
RSpec.describe 'the storm cleanups' do
  def reached_from(tables)
    pairs = ActiveRecord::Base.connection.select_rows(
      "SELECT confrelid::regclass::text, conrelid::regclass::text FROM pg_constraint WHERE contype = 'f'"
    )
    edges = pairs.group_by(&:first).transform_values { it.map(&:last) }
    reached = Set.new(tables)
    queue = tables.dup
    while (table = queue.shift)
      edges.fetch(table, []).each { |child| queue << child if reached.add?(child) }
    end
    reached
  end

  it "bin/storm's cleanup empties every table the specs empty" do
    named = Rails.root.join('bin/storm').read[/TRUNCATE (.*?) CASCADE/m, 1].gsub("\\\n", '').split(/,\s*/)

    expect(NonTransactionalCleanup::TABLES - reached_from(named).to_a).to eq([])
  end

  it 'rake test:storm empties every table the specs empty before a run, with the queue or without it' do
    source = Rails.root.join('lib/tasks/test/storm.rake').read
    always = source[/tables = %w\[(.*?)\]/, 1].split
    queue = source[/tables \+= %w\[(.*?)\]/, 1].split

    expect(NonTransactionalCleanup::TABLES - reached_from(always + queue).to_a - queue).to eq([])
  end
end

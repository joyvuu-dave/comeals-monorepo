# frozen_string_literal: true

require 'rails_helper'

# The scheduler runs each actor on its own thread and its own database
# connection, but lets only one SQL statement run at a time, and the seed
# picks whose statement runs next. So the same seed gives the same order
# of statements and the same outcomes, every time (challenge 31).
RSpec.describe Simulation::Scheduler do
  include_context 'with no test transaction'
  include_context 'with a pool for a simulation', 8

  before(:all) do
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      CREATE TABLE IF NOT EXISTS simulation_counters (id integer PRIMARY KEY, value integer NOT NULL)
    SQL
  end

  after(:all) { ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS simulation_counters') }

  before do
    ActiveRecord::Base.connection.execute('TRUNCATE simulation_counters')
    ActiveRecord::Base.connection.execute('INSERT INTO simulation_counters VALUES (1, 0), (2, 0)')
  end

  def sql(text) = ActiveRecord::Base.connection.execute(text)

  # Three plain statements each: no locks, no transactions.
  def run_plain(seed)
    scheduler = described_class.new(seed: seed)
    %i[a b].each do |name|
      scheduler.actor(name) do
        3.times { |i| sql("SELECT #{i} AS step_#{name}") }
      end
    end
    scheduler.run
  end

  # Both actors take the same row lock, so one of them waits in
  # PostgreSQL until the other commits.
  def run_locking(seed)
    scheduler = described_class.new(seed: seed)
    %i[a b].each do |name|
      scheduler.actor(name) do
        ActiveRecord::Base.transaction do
          sql('SELECT value FROM simulation_counters WHERE id = 1 FOR UPDATE')
          sql('UPDATE simulation_counters SET value = value + 1 WHERE id = 1')
        end
      end
    end
    scheduler.run
  end

  # Write skew at SERIALIZABLE: each reads the row the other writes. One
  # of the two must be refused, and which one depends on the order.
  def run_write_skew(seed)
    scheduler = described_class.new(seed: seed)
    { a: [1, 2], b: [2, 1] }.each do |name, (read, write)|
      scheduler.actor(name) do
        ActiveRecord::Base.transaction do
          sql("SELECT value FROM simulation_counters WHERE id = #{read}")
          sql("UPDATE simulation_counters SET value = value + 1 WHERE id = #{write}")
        end
        :committed
      rescue ActiveRecord::SerializationFailure
        :refused
      end
    end
    scheduler.run
  end

  # Each locks the two rows in the opposite order, so an interleaving
  # makes a lock cycle and PostgreSQL refuses one of them.
  def run_deadlock(seed)
    scheduler = described_class.new(seed: seed)
    { a: [1, 2], b: [2, 1] }.each do |name, rows|
      scheduler.actor(name) do
        ActiveRecord::Base.transaction do
          rows.each { |id| sql("SELECT value FROM simulation_counters WHERE id = #{id} FOR UPDATE") }
        end
        :committed
      rescue ActiveRecord::Deadlocked
        :deadlocked
      end
    end
    scheduler.run
  end

  def reset_counters
    sql('UPDATE simulation_counters SET value = 0')
  end

  it 'gives the same trace for the same seed' do
    first, second = Array.new(2) { run_plain(7).steps }
    expect(first).to eq(second)
  end

  it 'gives different orders for different seeds' do
    orders = (1..20).map { |seed| run_plain(seed).steps.sort_by(&:sent).map(&:actor) }
    expect(orders.uniq.size).to be > 1
  end

  it 'runs every statement of every actor, in each actor its own order' do
    steps = run_plain(3).steps
    %i[a b].each do |name|
      expect(steps.select { |s| s.actor == name }.map(&:sql))
        .to eq((0..2).map { |i| "SELECT #{i} AS step_#{name}" })
    end
  end

  it 'goes on with another actor while one waits for a lock, and replays the wait exactly' do
    traces = (1..10).map do |seed|
      Array.new(2) do
        reset_counters
        run_locking(seed).steps
      end
    end
    expect(traces).to all(satisfy { |first, second| first == second })
    expect(traces.flatten.select(&:waited)).not_to be_empty
  end

  # PostgreSQL refuses the COMMIT of the transaction it cancels, and Rails
  # sends a ROLLBACK after it anyway (spec/db/commit_refused_spec.rb).
  it 'refuses the same writer in a write skew every time the seed is replayed',
     server_notices: [ServerNotices::REFUSED_COMMIT] do
    outcomes = (1..10).map do |seed|
      Array.new(2) do
        reset_counters
        result = run_write_skew(seed)
        [result.steps, result.values]
      end
    end
    expect(outcomes).to all(satisfy { |first, second| first == second })
    # A seed that runs one transaction before the other refuses no one;
    # one that interleaves them refuses exactly one.
    refused = outcomes.map { |(_, values), _| values.values.count(:refused) }
    expect(refused.uniq.sort).to eq([0, 1])
  end

  it 'refuses the actor that closes a lock cycle, and the same one on every replay' do
    runs = (1..12).map { |seed| Array.new(2) { run_deadlock(seed) } }
    expect(runs).to all(satisfy { |first, second| first == second })

    deadlocked = runs.map(&:first).select { |result| result.values.value?(:deadlocked) }
    expect(deadlocked).not_to be_empty
    deadlocked.each do |result|
      first_waiter, closer = result.steps.select(&:waited).sort_by(&:sent).map(&:actor)
      expect(result.values).to eq(closer => :deadlocked, first_waiter => :committed)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Every Solid Queue process (the supervisor, the dispatcher, the worker and
# the scheduler) has a row in solid_queue_processes. Every 60 seconds each
# one writes the time into its own row (SolidQueue::Process#heartbeat):
#
#   BEGIN
#   SELECT * FROM solid_queue_processes WHERE id = $1 LIMIT 1 FOR UPDATE
#   UPDATE solid_queue_processes SET last_heartbeat_at = $1 WHERE id = $2
#   COMMIT
#
# The processes start together, so their heartbeats often run at the same
# moment. Every session runs at SERIALIZABLE (ADR 0005), and at
# SERIALIZABLE each heartbeat reads the row the other one writes:
#
#   - with a few rows in the table, PostgreSQL reads it with a sequential
#     scan, and that counts as a read of the whole table;
#   - with an index scan, it counts as a read of the primary key's index
#     page, and the UPDATE adds a new entry to that same page, because
#     last_heartbeat_at has an index of its own.
#
# So there are two read/write dependencies, one in each direction.
# PostgreSQL cannot put the two transactions in any order, and it cancels
# one with ActiveRecord::SerializationFailure. Solid Queue does not retry
# it: the heartbeat is lost, and the error is reported as unhandled.
#
# On shutdown the supervisor stops all its processes at once, and each
# one deletes its own row (SolidQueue::Process#deregister). With a
# sequential scan each DELETE reads the whole table too, so two of them
# fail the same way. (With an index scan they do not: a DELETE adds no
# index entry.) PostgreSQL picks a sequential scan for a table this small
# once it has statistics for it, which a long-running database has and a
# freshly emptied test table does not, so that example turns index scans
# off.
#
# Each example makes both transactions read before either one writes,
# which is the order that fails. Nothing waits on the clock: each thread
# stops after its read until the other one has read too.
RSpec.describe 'two Solid Queue processes writing their own rows at the same moment' do
  include_context 'with no test transaction'

  let(:supervisor) { register('Supervisor(fork)', 'supervisor-test') }
  let!(:dispatcher) { register('Dispatcher', 'dispatcher-test', supervisor: supervisor) }
  let!(:worker) { register('Worker', 'worker-test', supervisor: supervisor) }

  def register(kind, name, supervisor: nil)
    SolidQueue::Process.register(kind: kind, name: name, pid: 1, hostname: 'test', supervisor: supervisor,
                                 metadata: {})
  end

  # Runs the block for each process on a thread and a connection of its
  # own, and returns each thread's value: :ok, or the error's class and
  # first line.
  def at_the_same_moment(processes, pause_after:, sequential_scans: false, &)
    started = Concurrent::CountDownLatch.new(1)
    threads = []
    pause = pause_once(pause_after, threads, processes.size)

    ActiveRecord::Base.connection_pool.release_connection
    ActiveSupport::Notifications.subscribed(pause, 'sql.active_record') do
      processes.each do |process|
        threads << Thread.new do
          Thread.current.report_on_exception = false
          started.wait(10)
          on_its_own_connection(process, sequential_scans, &)
        end
      end
      started.count_down
      threads.map(&:value)
    end
  end

  # A thread stops right after the first statement it runs that matches
  # `pattern`, and goes on once every other thread has run one too. Only
  # the first: a fix that retries runs the statement again, and the other
  # thread may have finished by then.
  def pause_once(pattern, threads, count)
    barrier = Concurrent::CyclicBarrier.new(count)
    paused = Concurrent::Set.new
    lambda do |*, payload|
      next unless threads.include?(Thread.current) && payload[:sql].match?(pattern)
      next unless paused.add?(Thread.current)
      raise 'the other thread never ran its statement' unless barrier.wait(10)
    end
  end

  def on_its_own_connection(process, sequential_scans)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      index_scans(connection, :off) if sequential_scans
      yield SolidQueue::Process.find(process.id)
    ensure
      index_scans(connection, :on) if sequential_scans
    end
    :ok
  rescue StandardError => e
    "#{e.class}: #{e.message.lines.first&.strip}"
  end

  # Turns index scans off or on for one connection. Not RESET ALL,
  # which would also undo the connection's SERIALIZABLE setting.
  def index_scans(connection, value)
    connection.execute("SET enable_indexscan = #{value}")
    connection.execute("SET enable_bitmapscan = #{value}")
  end

  it 'records both heartbeats, with no error' do
    an_hour_ago = 1.hour.ago
    SolidQueue::Process.where(id: [dispatcher.id, worker.id]).update_all(last_heartbeat_at: an_hour_ago)

    outcomes = at_the_same_moment([dispatcher, worker], pause_after: /\ASELECT .* FOR UPDATE\z/, &:heartbeat)

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Process.where(id: [dispatcher.id, worker.id]).pluck(:last_heartbeat_at))
      .to all(be > an_hour_ago)
  end

  it 'removes both rows when the two processes shut down at the same moment, with no error' do
    outcomes = at_the_same_moment([dispatcher, worker], pause_after: /\ADELETE FROM "solid_queue_processes"/,
                                                        sequential_scans: true, &:deregister)

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Process.where(id: [dispatcher.id, worker.id])).to be_empty
  end
end

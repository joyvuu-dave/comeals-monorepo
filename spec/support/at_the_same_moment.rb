# frozen_string_literal: true

# Runs two or more database operations so that each one has done its read
# before any of them writes, which is the order in which PostgreSQL's
# SERIALIZABLE check cancels one of them. Nothing waits on the clock.
#
#   outcomes = at_the_same_moment(
#     [/\ASELECT .* FOR UPDATE/, -> { process_a.heartbeat }],
#     [/\ASELECT .* FOR UPDATE/, -> { process_b.heartbeat }]
#   )
#
# Each operation runs on a thread and a database connection of its own. A
# thread stops right after the first statement it runs that matches its
# pattern, and goes on once every other thread has run its own. Only the
# first: a fix that retries runs the statement again, and the other
# threads may have finished by then. The result is each thread's value:
# :ok, or the error's class and first line.
#
# A block, if given, runs once when every thread has stopped, before any
# of them goes on.
#
# sequential_scans: true turns index scans off on those connections.
# PostgreSQL picks a sequential scan for a small table once it has
# statistics for it, which a long-running database has and a freshly
# emptied test table does not.
#
# Use with include_context 'with no test transaction': the threads'
# connections cannot see rows that the example's transaction has not
# committed.
module AtTheSameMoment
  def at_the_same_moment(*steps, sequential_scans: false, &when_all_paused)
    started = Concurrent::CountDownLatch.new(1)
    threads = []
    pause = pause_once(steps.map(&:first), threads, when_all_paused)

    ActiveRecord::Base.connection_pool.release_connection
    ActiveSupport::Notifications.subscribed(pause, 'sql.active_record') do
      steps.each do |(_, operation)|
        threads << Thread.new do
          Thread.current.report_on_exception = false
          started.wait(10)
          on_its_own_connection(operation, sequential_scans)
        end
      end
      started.count_down
      threads.map(&:value)
    end
  end

  private

  def pause_once(patterns, threads, when_all_paused)
    barrier = Concurrent::CyclicBarrier.new(patterns.size, &when_all_paused)
    paused = Concurrent::Set.new
    lambda do |*, payload|
      index = threads.index(Thread.current)
      next unless index && payload[:sql].match?(patterns.fetch(index))
      next unless paused.add?(Thread.current)
      raise 'another thread never ran its statement' unless barrier.wait(10)
    end
  end

  def on_its_own_connection(operation, sequential_scans)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      index_scans(connection, :off) if sequential_scans
      operation.call
    ensure
      index_scans(connection, :on) if sequential_scans
    end
    :ok
  rescue StandardError => e
    "#{e.class}: #{e.message.lines.first&.strip}"
  end

  # Not RESET ALL, which would also undo the connection's SERIALIZABLE
  # setting.
  def index_scans(connection, value)
    connection.execute("SET enable_indexscan = #{value}")
    connection.execute("SET enable_bitmapscan = #{value}")
  end
end

RSpec.configure { |config| config.include AtTheSameMoment }

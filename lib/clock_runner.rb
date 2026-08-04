# frozen_string_literal: true

# Runs one scheduled rake task for the clock process (lib/clock.rb).
module ClockRunner
  def self.run_task(name)
    # Rufus-scheduler runs each job in its own worker thread. A thread that
    # queries the database checks out a connection and keeps it; only the
    # executor's completion hooks give it back. Without this wrap, worker
    # threads hold both connections in the pool and every later task fails
    # with ConnectionTimeoutError.
    Rails.application.executor.wrap do
      Rake::Task[name].invoke
    end
  rescue StandardError => e
    # rubocop:disable Rails/Output -- clock process; stdout IS the log
    puts "[clock] #{Time.current.strftime('%H:%M:%S')} FAILED: #{name} -- #{e.message}"
    # rubocop:enable Rails/Output
    Rails.logger.error("[clock] #{name} failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  ensure
    # Must run even when invoke raises: rake caches the failure and every
    # later invoke re-raises it without executing until the task is reenabled.
    Rake::Task[name].reenable
  end
end

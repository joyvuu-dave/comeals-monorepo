# frozen_string_literal: true

# Runs one scheduled rake task for the clock process (lib/clock.rb).
module ClockRunner
  def self.run_task(name)
    Rake::Task[name].invoke
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

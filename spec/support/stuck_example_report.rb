# frozen_string_literal: true

# When one example runs for more than four minutes, prints which example
# it is and where every thread of this process is, once, to the
# terminal. A stuck example otherwise runs until CI's job limit cancels
# the job, and RSpec's dots say nothing about which one it was. The case
# that needed it: on Linux only, a shard of the suite stopped for good,
# and the same shard in the same order passed on the laptop.
#
# One thread for the whole run, not one per example, so a spec that
# counts this process's threads sees the same count before and after
# its example. RSPEC_STUCK_SECONDS sets the limit.
class StuckExampleReport
  def initialize(out, seconds)
    @out = out
    @seconds = seconds
    @lock = Mutex.new
    @example = nil
    @started = nil
    @reported = nil
  end

  def start
    @thread = Thread.new do
      loop do
        sleep 10
        check
      end
    end
  end

  def stop = @thread&.kill

  def begin_example(location)
    @lock.synchronize do
      @example = location
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  def end_example = @lock.synchronize { @example = nil }

  private

  def check
    example, started = @lock.synchronize { [@example, @started] }
    return if example.nil? || example == @reported
    return if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < @seconds

    @reported = example
    @out.puts("\n=== #{example} has run for more than #{@seconds} seconds. Where each thread is:")
    Thread.list.each { |thread| @out.puts("--- #{thread.inspect}", thread.backtrace&.first(40)) }
    @out.flush
  end
end

RSpec.configure do |config|
  report = StuckExampleReport.new(config.error_stream, Integer(ENV.fetch('RSPEC_STUCK_SECONDS', 240)))

  config.before(:suite) { report.start }
  config.after(:suite) { report.stop }
  config.around do |example|
    report.begin_example(example.location)
    example.run
  ensure
    report.end_example
  end
end

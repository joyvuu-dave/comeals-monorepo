# frozen_string_literal: true

require 'time'

# For a Ruby script that watches the clock (bin/watch-deploy). Its time runs
# FAKE_CLOCK_SPEED times faster than real time from FAKE_CLOCK_START, and its
# sleeps are that much shorter, so a 30-minute watch takes seconds.
# FAKE_CLOCK_JUMP="60:600" adds 600 seconds once 60 seconds have passed, the
# way the clock jumps when a laptop wakes from sleep.
module FakeClock
  SPEED = Float(ENV.fetch('FAKE_CLOCK_SPEED', '1'))
  START = Time.iso8601(ENV.fetch('FAKE_CLOCK_START')).to_f
  JUMP_AT, JUMP_BY = ENV.fetch('FAKE_CLOCK_JUMP', '').split(':').map(&:to_f)

  # Time starts at the first question, so the time Ruby takes to load the
  # script does not count, and a spec can name the exact start.
  REAL_START = [] # rubocop:disable Style/MutableConstant -- filled in at the first question

  def self.seconds
    REAL_START[0] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    passed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - REAL_START[0]) * SPEED
    passed += JUMP_BY if JUMP_AT && passed >= JUMP_AT
    START + passed
  end

  # Prepended to Time's singleton class.
  module Now
    def now(...) = at(FakeClock.seconds)
  end
end

Time.singleton_class.prepend(FakeClock::Now)

class Object
  private

  def sleep(seconds) = Kernel.sleep(seconds / FakeClock::SPEED)
end

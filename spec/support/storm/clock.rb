# frozen_string_literal: true

module Storm
  # Where the storm reads the time: each client's deadline and each
  # request's ms, and the settler's, the jobs' and the admin's deadline.
  # A simulation passes its own clock instead (spec/support/simulation).
  MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
end

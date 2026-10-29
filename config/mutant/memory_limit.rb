# frozen_string_literal: true
# typed: false

# The most memory one process that tests a mutation may use.
#
# Some mutations turn a loop that ends into one that never ends, and some
# of those also add to a list on every turn. In LiveUpdate.calendar_range,
# `while month <= last` becoming `while true` adds a new month to a Set
# forever. Such a process uses all the memory the machine has long before
# the mutation timeout (300 s in .mutant.yml). On GitHub that ended a whole
# piece twice on 2026-10-16 (exit code 143, no artifact), so every other
# subject in the piece lost its result too. On a laptop it slows down
# everything else that runs.
#
# With the limit, the process ends by itself with an error. Mutant counts
# that as a process abort, and .mutant.yml counts an abort as not killed,
# so the mutation is listed with the other survivors.
#
# Linux enforces RLIMIT_DATA: an allocation past it fails, and Ruby raises
# NoMemoryError. When the allocation that fails is Ruby's own (growing the
# heap during garbage collection), Ruby cannot raise, and the process
# crashes instead (a [BUG] report with SIGABRT, or SIGSEGV). Mutant counts
# every one of these endings as a process abort.
#
# macOS accepts the limit but does not enforce it, so there a thread
# checks the size of the process once a second and ends the process when
# it is over the limit. A process can pass the limit there by what it
# allocates in one second (about 1 GB in the spec's loop), which is still
# far less than five minutes of it.
#
# The size it checks on macOS is the memory footprint (phys_footprint,
# what Activity Monitor shows as "Memory"), not the resident size. When
# the machine is short of memory, as during a full bin/check, macOS
# compresses or swaps pages, and those pages leave the resident size. A
# process that grew by 400 MB could then show less than the limit, and
# go on growing (#250). The footprint counts them.
#
# 2 GiB is about seven times what a worker uses after it has loaded every
# spec file (290 MB, measured 2026-10-16), and four workers at the limit
# still fit in the 16 GB of a GitHub machine.
module MutantMemoryLimit
  BYTES = 2 * (1024**3)

  # The exit status of a process the watch thread ended.
  WATCH_EXIT_STATUS = 98

  # For proc_pid_rusage on macOS: struct rusage_info_v0 in
  # <sys/resource.h> is a 16-byte uuid, then eleven 64-bit counts, and
  # phys_footprint is the eighth of them.
  RUSAGE_INFO_V0 = 0
  RUSAGE_INFO_V0_SIZE = 16 + (11 * 8)
  PHYS_FOOTPRINT_OFFSET = 16 + (7 * 8)

  class << self
    def apply(bytes = BYTES)
      if linux?
        Process.setrlimit(Process::RLIMIT_DATA, bytes, bytes)
      else
        watch(bytes)
      end
    end

    # What the limit is compared with: the data size on Linux (what
    # RLIMIT_DATA counts), the memory footprint on macOS (what the watch
    # thread reads).
    def current_bytes
      if linux?
        Integer(File.read('/proc/self/status')[/^VmData:\s+(\d+) kB$/, 1]) * 1024
      else
        footprint_bytes
      end
    end

    private

    def footprint_bytes
      require 'fiddle'
      rusage = Fiddle::Function.new(
        Fiddle::Handle::DEFAULT['proc_pid_rusage'],
        [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )
      info = Fiddle::Pointer.malloc(RUSAGE_INFO_V0_SIZE, Fiddle::RUBY_FREE)
      raise "proc_pid_rusage failed: #{Fiddle.last_error}" unless rusage.call(Process.pid, RUSAGE_INFO_V0, info).zero?

      info[PHYS_FOOTPRINT_OFFSET, 8].unpack1('Q')
    end

    def linux?
      RUBY_PLATFORM.include?('linux')
    end

    def watch(bytes)
      # rubocop:disable-next ThreadSafety/NewThread -- one thread in a process that tests one mutation; it only reads the process size
      Thread.new do
        loop do
          sleep 1
          next if current_bytes <= bytes

          warn "MutantMemoryLimit: #{current_bytes / (1024**2)} MB is over the limit of #{bytes / (1024**2)} MB"
          # exit!, not exit: the process must end now, without the at_exit
          # hooks and without writing a result for mutant to read.
          exit!(WATCH_EXIT_STATUS) # rubocop:disable Rails/Exit
        end
      end
    end
  end
end

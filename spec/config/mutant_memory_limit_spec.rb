# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require Rails.root.join('config/mutant/memory_limit').to_s

# config/mutant/memory_limit.rb ends a process that tests a mutation when
# it grows past a limit. Each example starts a small, fresh Ruby process
# that loads only that file, gives itself a limit 100 MB above its size,
# and grows a list without end, the way a mutation of
# LiveUpdate.calendar_range grows a Set. A fresh process, not a fork of
# this one: a fork carries this process's at_exit hooks (SimpleCov's among
# them), and on CI on 2026-10-16 they set the exit status of a forked
# child that ran out of memory to success.
#
# On Linux the kernel refuses the allocation that would pass the limit.
# Ruby then raises NoMemoryError, or, when the allocation was Ruby's own
# and cannot raise, crashes (CI saw SIGABRT and SIGSEGV). Mutant counts
# every one of these as a process abort, so the Linux example checks only
# that the process ended with an error before its loop finished. On macOS
# the watch thread ends it at its next check, with its own exit status.
RSpec.describe MutantMemoryLimit do
  def ran_on_after_the_limit = 2

  def run_child(body)
    script = <<~RUBY
      $stderr.reopen(File::NULL) # a crash report is long, and not this spec's output
      require #{Rails.root.join('config/mutant/memory_limit').to_s.dump}
      #{body}
    RUBY
    _out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    status
  end

  it 'ends a process that grows past the limit' do
    status = run_child(<<~RUBY)
      MutantMemoryLimit.apply(MutantMemoryLimit.current_bytes + (100 * (1024**2)))
      list = []
      # 1 KB a turn. Stop at 400 MB, so a limit that does not work cannot
      # use up this machine's memory.
      400_000.times { list << ('x' * 1024) }
      sleep 3 # time for the watch thread's next check
      exit!(#{ran_on_after_the_limit})
    RUBY

    if RUBY_PLATFORM.include?('linux')
      expect(status.success?).not_to be(true) # nil when a signal ended it
      expect(status.exitstatus).not_to eq(ran_on_after_the_limit)
    else
      expect(status.exitstatus).to eq(described_class::WATCH_EXIT_STATUS)
    end
  end

  it 'leaves a process under the limit alone' do
    status = run_child(<<~RUBY)
      MutantMemoryLimit.apply
      list = Array.new(10_000) { 'x' * 1024 }
      sleep 1.5 # one check of the watch thread
      exit!(list.size == 10_000 ? 0 : 1)
    RUBY

    expect(status.exitstatus).to eq(0)
  end
end

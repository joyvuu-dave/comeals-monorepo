# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('config/mutant/memory_limit').to_s

# config/mutant/memory_limit.rb ends a process that tests a mutation when
# it grows past a limit. This forks a child, gives it a limit 100 MB above
# its size now, and grows a list in it without end, the way a mutation of
# LiveUpdate.calendar_range grows a Set. The child must end with an error
# and not run on.
#
# CI runs this on Linux, where the kernel refuses the allocation that would
# pass the limit. bin/check runs it on macOS, where the watch thread ends
# the child at its next check, up to a second after it passed the limit. The child leaves with
# exit!, so it never runs the at_exit hooks it shares with this process
# (SimpleCov's among them).
RSpec.describe MutantMemoryLimit do
  def ran_on_after_the_limit = 2
  def ended_by_the_kernel = 3

  def child_status
    pid = fork do
      described_class.apply(described_class.current_bytes + (100 * (1024**2)))
      list = []
      begin
        # 1 KB a turn. Stop at 400 MB, so a limit that does not work cannot
        # use up this machine's memory.
        400_000.times { list << ('x' * 1024) }
        sleep 3 # time for the watch thread's next check
        exit!(ran_on_after_the_limit) # rubocop:disable Rails/Exit
      rescue NoMemoryError
        exit!(ended_by_the_kernel) # rubocop:disable Rails/Exit
      end
    end
    Process.wait2(pid).last
  end

  it 'ends a process that grows past the limit' do
    expected = RUBY_PLATFORM.include?('linux') ? ended_by_the_kernel : described_class::WATCH_EXIT_STATUS
    expect(child_status.exitstatus).to eq(expected)
  end

  it 'leaves a process under the limit alone' do
    pid = fork do
      described_class.apply
      list = Array.new(10_000) { 'x' * 1024 }
      sleep 1.5 # one check of the watch thread
      exit!(list.size == 10_000 ? 0 : 1) # rubocop:disable Rails/Exit
    end
    expect(Process.wait2(pid).last.exitstatus).to eq(0)
  end
end

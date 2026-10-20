# frozen_string_literal: true

require 'coverage'
require 'fileutils'

# Coverage of the Ruby scripts in bin/, which the specs in spec/bin run in
# processes of their own (spec/support/ruby_script.rb).
#
# At the start of a run, spec/spec_helper.rb makes a new folder for this
# run and names it in CHILD_COVERAGE_DIR, which every script process the
# run starts inherits. Each of those processes measures itself with Ruby's
# Coverage (spec/bin/preload/child_coverage.rb) and, when it exits, writes
# the counts for bin/ into that folder. When SimpleCov reads this
# process's Coverage.result at the end of the run, the counts in the folder
# are added to it. So they become part of this run's own result ("RSpec",
# or "RSpec shard <n>" on CI), and a result written by an earlier run, in
# another folder, can never count.
module ChildCoverage
  BASE = File.expand_path('../tmp/child-coverage', __dir__)

  module_function

  # A folder no earlier run used: this process's id and the time.
  def start_run(base = BASE)
    dir = File.join(base, "#{Process.pid}-#{Time.now.utc.strftime('%Y%m%d%H%M%S%N')}")
    FileUtils.mkdir_p(dir)
    ENV['CHILD_COVERAGE_RUNNER'] = Process.pid.to_s
    ENV['CHILD_COVERAGE_DIR'] = dir
  end

  # The counts every script process wrote into dir, added together.
  def read(dir)
    Dir.glob(File.join(dir, '*.marshal')).reduce({}) do |total, file|
      merge(total, Marshal.load(File.binread(file))) # rubocop:disable Security/MarshalLoad -- written by this run's own processes
    end
  end

  # Two Coverage.result hashes added together: line counts line by line,
  # branch counts branch by branch.
  def merge(first, second)
    first.merge(second) do |_file, mine, theirs|
      mine.merge(theirs) { |kind, a, b| merge_kind(kind, a, b) }
    end
  end

  def merge_kind(kind, mine, theirs)
    case kind
    when :lines then mine.zip(theirs).map { |a, b| a && b ? a + b : a || b }
    when :branches then mine.merge(theirs) { |_, arms, other| arms.merge(other) { |_, a, b| a + b } }
    else mine
    end
  end

  # Prepended to Coverage's singleton class in the RSpec process. Only that
  # process adds the folder's counts, not a process forked from it.
  module AddRun
    def result(...)
      dir = ENV.fetch('CHILD_COVERAGE_DIR', nil)
      return super unless dir && File.directory?(dir) && ENV['CHILD_COVERAGE_RUNNER'] == Process.pid.to_s

      counts = ChildCoverage.read(dir)
      FileUtils.remove_entry(dir)
      ChildCoverage.merge(super, counts)
    end
  end
end

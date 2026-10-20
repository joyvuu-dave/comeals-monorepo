# frozen_string_literal: true

# Measures a Ruby script from bin/ that a spec runs in a process of its own
# (spec/support/ruby_script.rb loads this file with RUBYOPT=-r). When the
# process exits, it writes the counts for bin/ into this run's folder,
# CHILD_COVERAGE_DIR, and the RSpec process adds them to its own result
# (spec/child_coverage.rb). With no folder named (bin/mutant runs the suite
# without coverage), it measures nothing.
if (dir = ENV.fetch('CHILD_COVERAGE_DIR', nil))
  require 'coverage'

  Coverage.start(lines: true, branches: true)
  bin = File.expand_path('../../../bin/', __dir__)
  at_exit do
    counts = Coverage.result.select { |path, _| path.start_with?(bin) }
    File.binwrite(File.join(dir, "#{Process.pid}-#{rand(1_000_000)}.marshal"), Marshal.dump(counts))
  end
end

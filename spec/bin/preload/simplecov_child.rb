# frozen_string_literal: true

# Measures a Ruby script from bin/ that a spec runs in a process of its own
# (bin/mutant-report, bin/tapioca, bin/setup, the binstubs). The spec loads
# this file into that process with RUBYOPT=-r (spec/support/ruby_script.rb).
# It stores the process's coverage in coverage/.resultset.json under a name
# of its own, and the suite's SimpleCov merges it into its report and holds
# it to the same 100% minimum as the app (spec/spec_helper.rb).
#
# The name comes from the spec (the example and a count), so a second run
# of the suite replaces the first run's entries instead of adding to them.
# The result is stored from an at_exit of this file, not SimpleCov's own:
# SimpleCov stores nothing when the process exits with an error, and
# several of these scripts are run on purpose to see them refuse.
unless ENV['MUTANT']
  require 'simplecov'

  SimpleCov.root(File.expand_path('../../..', __dir__))
  SimpleCov.command_name(ENV.fetch('SIMPLECOV_CHILD_NAME'))
  SimpleCov.print_errors(false)
  SimpleCov.finalize_merge(false)
  SimpleCov.external_at_exit = true
  SimpleCov.start('rails') { enable_coverage :branch }
  at_exit { SimpleCov.result }
end

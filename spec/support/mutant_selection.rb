# frozen_string_literal: true

# Tags spec files so mutant runs their examples for the classes they
# prove. Only active under bin/mutant (ENV['MUTANT']); plain rspec never
# reads this metadata.
#
# Mutant picks the examples for a subject by the first word of each
# example's description: `describe Settlement` examples run for every
# Settlement method, and nothing else does. Most of the examples that
# actually check settlement arithmetic are described by a sentence
# ('Settlement contract', 'billing:recalculate correctness'), or by a
# class the arithmetic runs through (Reconciliation, LedgerVerification),
# so mutant would never run them. A survivor from such a run means
# nothing.
#
# The list in spec/support/mutant/specs.rb says, for each such spec
# file, which classes it proves, and this file tags the examples of
# that file with them. Every method of a named class runs the whole
# file, so a class named there should be one whose behaviour the file
# checks, not one it only calls on the way. Add a row there when a new
# spec checks a class under a sentence description. That file also
# lists the specs mutant must never run.
#
# This file does not set the order the examples run in. mutant-rspec
# 0.17 sets its own order before each mutation: the order the files
# load, by path, then by line (#185). Mutant stops at the first example
# that fails, so an example meant to end a mutation that never stops
# must be in the first of the selected files by path.
#
# The first run (2026-09-08) had 12 examples selected for
# Settlement.truncate_toward_zero, none of which read its result, and
# 28 of 130 mutations survived, including "drop the rounding".
return unless ENV['MUTANT']

require_relative 'mutant/specs'

RSpec.configure do |config|
  selections = MUTANT_SPECS.merge(MUTANT_SIG_CHECK_SPECS.index_with([]))
  selections.each do |path, expressions|
    absolute = Rails.root.join(path).to_s
    raise "spec/support/mutant/specs.rb names a file that does not exist: #{path}" unless File.exist?(absolute)

    config.define_derived_metadata(file_path: ->(file) { File.expand_path(file) == absolute }) do |metadata|
      metadata[:mutant_expression] = expressions
    end
  end
end

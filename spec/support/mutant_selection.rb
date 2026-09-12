# frozen_string_literal: true

# Which examples mutant runs for the money path. Only active under
# bin/mutant (ENV['MUTANT']); plain rspec never reads this metadata.
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
# This list says, for each such spec file, which classes it proves.
# Every method of a named class runs the whole file, so a class named
# here should be one whose behaviour the file checks, not one it merely
# calls on the way. Add a row when a new spec checks a class under a
# sentence description. The first block is the money path; the second
# is everything else, added when mutant's subjects grew to the whole
# app (2026-09-12).
#
# The first run (2026-09-08) had 12 examples selected for
# Settlement.truncate_toward_zero, none of which read its result, and
# 28 of 130 mutations survived, including "drop the rounding".
return unless ENV['MUTANT']

require_relative 'mutant/specs'

RSpec.configure do |config|
  config.register_ordering(:global) do |items|
    items.sort_by do |item|
      path = item.metadata[:file_path].delete_prefix('./')
      rank = MUTANT_DIRECTORY_ORDER.index { |dir| path.start_with?("#{dir}/") } || MUTANT_DIRECTORY_ORDER.size
      [rank, path, item.metadata[:line_number]]
    end
  end

  selections = MUTANT_SPECS.merge(MUTANT_SIG_CHECK_SPECS.index_with([]))
  selections.each do |path, expressions|
    absolute = Rails.root.join(path).to_s
    raise "spec/support/mutant_selection.rb names a file that does not exist: #{path}" unless File.exist?(absolute)

    config.define_derived_metadata(file_path: ->(file) { File.expand_path(file) == absolute }) do |metadata|
      metadata[:mutant_expression] = expressions
    end
  end
end

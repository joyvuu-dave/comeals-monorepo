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
# here should be one whose numbers the file checks, not one it merely
# calls on the way. Add a row when a new spec checks money arithmetic.
#
# The first run (2026-09-08) had 12 examples selected for
# Settlement.truncate_toward_zero, none of which read its result, and
# 28 of 130 mutations survived, including "drop the rounding".
return unless ENV['MUTANT']

MUTANT_MONEY_SPECS = {
  'spec/services/settlement_allocate_to_cents_on_random_ledgers_spec.rb' => %w[Settlement],
  # The oracle comparison describes MealLedger, so it runs for MealLedger
  # on its own; this row adds it to Settlement for the rounding.
  'spec/services/meal_ledger_against_plain_ledger_spec.rb' => %w[Settlement],
  'spec/services/settlement_contract_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/services/ledger_verification_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/services/settle_and_notify_spec.rb' => %w[Settlement Reconciliation BalanceRecalculation],
  'spec/services/meal_cost_summary_spec.rb' => %w[MealLedger],
  'spec/models/reconciliation_spec.rb' => %w[Reconciliation Settlement MealLedger],
  'spec/models/reconciliation_awkward_bills_spec.rb' => %w[Reconciliation Settlement MealLedger],
  'spec/models/reconciliation_balance_spec.rb' => %w[Reconciliation Settlement],
  'spec/models/reconciliation_types_spec.rb' => %w[Reconciliation],
  'spec/helpers/balance_display_helper_spec.rb' => %w[MealLedger],
  'spec/mailers/reconciliation_mailer_spec.rb' => %w[Reconciliation],
  'spec/jobs/refresh_balances_job_spec.rb' => %w[BalanceRecalculation],
  'spec/tasks/settlement_matches_running_balance_spec.rb' =>
    %w[Settlement Reconciliation MealLedger BalanceRecalculation],
  'spec/tasks/billing_recalculate_correctness_spec.rb' => %w[BalanceRecalculation MealLedger],
  'spec/tasks/billing_recalculate_snapshot_spec.rb' => %w[BalanceRecalculation],
  'spec/tasks/billing_recalculate_spec.rb' => %w[BalanceRecalculation],
  'spec/tasks/reconciliations_create_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/tasks/ledger_verify_spec.rb' => %w[Settlement Reconciliation],
  # The race spec is the only one that fails when assign_meals stops
  # taking the row lock. The two trigger specs in spec/db are not here:
  # they check database triggers, which mutant does not touch, and cost
  # 20 seconds a pass.
  'spec/db/settlement_race_spec.rb' => %w[Settlement],
  # A method-level entry runs only for that method, and for that method
  # nothing else runs: this is the one caller of rewrite!, a repair step.
  'spec/db/settled_balance_triggers_spec.rb' => %w[Settlement#rewrite!],
  'spec/requests/api/v1/live_update_contract_spec.rb' => %w[Settlement],
  'spec/tasks/reconciliations_email_spec.rb' => %w[Reconciliation],
  'spec/requests/api/v1/reconciliations_create_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/requests/api/v1/reconciliations_preview_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/requests/api/v1/settled_meal_cache_spec.rb' => %w[Settlement],
  'spec/requests/admin/reconciliation_show_spec.rb' => %w[Reconciliation],
  'spec/requests/admin/resident_statement_spec.rb' => %w[Reconciliation]
}.freeze

# Mutant runs the selected examples with --fail-fast, so a mutation is
# killed as soon as one example fails. The cheap, exact examples should
# come first: a unit spec on a service fails in a fraction of a second,
# a request spec or the race spec takes seconds to get to the same
# assertion. Ranked by directory; within a directory, by path and line.
MUTANT_DIRECTORY_ORDER = %w[
  spec/services spec/models spec/helpers spec/tasks spec/jobs
  spec/mailers spec/requests spec/db
].freeze

RSpec.configure do |config|
  config.register_ordering(:global) do |items|
    items.sort_by do |item|
      path = item.metadata[:file_path].delete_prefix('./')
      rank = MUTANT_DIRECTORY_ORDER.index { |dir| path.start_with?("#{dir}/") } || MUTANT_DIRECTORY_ORDER.size
      [rank, path, item.metadata[:line_number]]
    end
  end

  MUTANT_MONEY_SPECS.each do |path, expressions|
    absolute = Rails.root.join(path).to_s
    raise "spec/support/mutant_selection.rb names a file that does not exist: #{path}" unless File.exist?(absolute)

    config.define_derived_metadata(file_path: ->(file) { File.expand_path(file) == absolute }) do |metadata|
      metadata[:mutant_expression] = expressions
    end
  end
end

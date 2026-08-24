# frozen_string_literal: true

namespace :billing do
  desc 'Recalculate all resident balances from source records. Safe to run at any time.'
  task recalculate: :environment do
    # The scheduled version is RefreshBalancesJob (config/recurring.yml).
    # This task is the same job, for a person at a terminal.
    RefreshBalancesJob.perform_now
  end
end

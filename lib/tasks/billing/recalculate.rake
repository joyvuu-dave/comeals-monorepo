# frozen_string_literal: true

namespace :billing do
  desc 'Recalculate all resident balances from source records. Safe to run at any time.'
  task recalculate: :environment do
    Healthcheck.monitor('billing-recalculate') do
      start_time = Time.current

      # The work is BalanceRecalculation, so that a settlement can run it
      # too (SettleAndNotify). This task is the nightly schedule and the
      # healthchecks.io ping around it.
      written = BalanceRecalculation.call

      total_time = Time.current - start_time
      Rails.logger.info("billing:recalculate wrote #{written} balances in #{total_time.round(2)}s")
    end
  end
end

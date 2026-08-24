# frozen_string_literal: true

namespace :ledger do
  desc 'Check every settled balance against its source data. Records the run in ledger_check_runs.'
  task verify: :environment do
    # The scheduled version is VerifyLedgerJob (config/recurring.yml).
    VerifyLedgerJob.perform_now
  end
end

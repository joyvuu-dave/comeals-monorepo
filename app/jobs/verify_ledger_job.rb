# frozen_string_literal: true

# Check every settled balance against its source data. LedgerVerification
# records its own detailed run in ledger_check_runs and raises on a
# mismatch, so a failed check is a failed job, a failed ping, and a
# Bugsnag report — never a quiet log line.
class VerifyLedgerJob < RecurringJob
  HEALTHCHECK = 'ledger-verify'

  def run
    run = LedgerVerification.call
    { ledger_check_run_id: run.id, reconciliations_checked: run.reconciliations_checked }
  end
end

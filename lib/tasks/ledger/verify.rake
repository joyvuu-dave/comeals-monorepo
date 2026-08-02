# frozen_string_literal: true

namespace :ledger do
  desc 'Check every settled balance against its source data. Records the run in ledger_check_runs.'
  task verify: :environment do
    # Healthcheck.monitor turns a raise into a /fail ping, so a night the
    # books do not tie out becomes an email. It also covers the case no code
    # inside the task can catch: the task not running at all.
    Healthcheck.monitor('ledger-verify') do
      LedgerVerification.call
    end
  end
end

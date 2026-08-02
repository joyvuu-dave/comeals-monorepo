# frozen_string_literal: true

# == Schema Information
#
# Table name: ledger_check_runs
#
#  id                      :bigint           not null, primary key
#  details                 :jsonb            not null
#  error                   :text
#  finished_at             :datetime         not null
#  mismatch_count          :integer          default(0), not null
#  reconciliations_checked :integer          default(0), not null
#  started_at              :datetime         not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#
# Indexes
#
#  index_ledger_check_runs_on_started_at  (started_at)
#

FactoryBot.define do
  factory :ledger_check_run do
    started_at { 2.minutes.ago }
    finished_at { 1.minute.ago }
    reconciliations_checked { 3 }
    mismatch_count { 0 }
    details { [] }

    # Amounts are strings here because that is how LedgerVerification writes
    # them — JSON numbers are floats, and money never touches one.
    trait :with_mismatches do
      mismatch_count { 1 }
      details do
        [
          {
            'reconciliation_id' => 1,
            'date' => '2026-07-01',
            'differences' => [
              { 'resident_id' => 1, 'stored' => '40.0', 'source' => '39.0' },
              { 'resident_id' => 2, 'stored' => '-40.0', 'source' => nil }
            ]
          }
        ]
      end
    end

    trait :errored do
      error { 'PG::ConnectionBad: connection lost' }
    end
  end
end

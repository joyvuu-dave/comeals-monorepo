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
require 'rails_helper'

RSpec.describe LedgerCheckRun do
  def build_run(**attributes)
    described_class.create!(
      { started_at: 2.minutes.ago, finished_at: 1.minute.ago }.merge(attributes)
    )
  end

  describe 'outcomes' do
    # Three states, not two. A run that could not finish says nothing about
    # the books, which is different from one that finished and found them
    # right — and the difference matters at 3am when an email arrives.
    it 'passes when it finished and found nothing' do
      run = build_run(reconciliations_checked: 3, mismatch_count: 0)

      expect(run).to be_passed
      expect(run).not_to be_failed
      expect(run).not_to be_errored
    end

    it 'fails when it finished and found something' do
      run = build_run(reconciliations_checked: 3, mismatch_count: 1)

      expect(run).to be_failed
      expect(run).not_to be_passed
    end

    it 'is neither passed nor failed when it could not finish' do
      run = build_run(reconciliations_checked: 1, error: 'PG::ConnectionBad: gone')

      expect(run).to be_errored
      expect(run).not_to be_passed
      expect(run).not_to be_failed
    end
  end

  describe 'immutability' do
    it 'refuses an update' do
      run = build_run(mismatch_count: 0)

      expect(run.update(mismatch_count: 5)).to be(false)
      expect(run.reload.mismatch_count).to eq(0)
    end

    it 'refuses a destroy' do
      run = build_run

      expect(run.destroy).to be(false)
      expect(described_class.exists?(run.id)).to be(true)
    end

    # The trigger, not the model. This is the path that matters — a record
    # anyone can rewrite from psql is not evidence of anything.
    it 'refuses an update that skips Rails' do
      run = build_run(mismatch_count: 0)

      expect { described_class.where(id: run.id).update_all(mismatch_count: 5) }
        .to raise_error(ActiveRecord::StatementInvalid, /ledger_check_runs refused/)
    end

    it 'refuses a delete that skips Rails' do
      run = build_run

      expect { described_class.where(id: run.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /ledger_check_runs refused/)
    end

    it 'lets a deliberate repair through, so rows can still be pruned' do
      run = build_run

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        described_class.where(id: run.id).delete_all
      end

      expect(described_class.exists?(run.id)).to be(false)
    end
  end

  describe 'database constraints' do
    it 'refuses a run that finished before it started' do
      expect { build_run(started_at: 1.minute.ago, finished_at: 2.minutes.ago) }
        .to raise_error(ActiveRecord::StatementInvalid, /finished_after_started/)
    end

    it 'refuses a negative mismatch count' do
      expect { described_class.new(started_at: 2.minutes.ago, finished_at: 1.minute.ago, mismatch_count: -1).save! }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'ordering' do
    it 'lists the most recent run first' do
      older = build_run(started_at: 2.days.ago, finished_at: 2.days.ago + 1.minute)
      newer = build_run(started_at: 1.hour.ago, finished_at: 1.hour.ago + 1.minute)

      expect(described_class.recent.to_a).to eq([newer, older])
    end
  end
end

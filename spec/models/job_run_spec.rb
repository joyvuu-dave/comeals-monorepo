# frozen_string_literal: true

require 'rails_helper'

RSpec.describe JobRun do
  def run!(name: 'refresh_balances', outcome: 'ok', finished_at: Time.current)
    described_class.create!(name: name, started_at: finished_at - 1.second, finished_at: finished_at, outcome: outcome)
  end

  it 'answers when a job last succeeded, ignoring failures' do
    run!(finished_at: 2.days.ago)
    run!(finished_at: 1.hour.ago, outcome: 'failed')

    expect(described_class.last_success_at('refresh_balances')).to be_within(1.second).of(2.days.ago)
    expect(described_class.last_success_at('verify_ledger')).to be_nil
  end

  it 'refuses an update at the database' do
    run = run!

    expect { run.update_column(:outcome, 'failed') }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
  end

  it 'refuses a delete at the database' do
    run = run!

    expect { run.delete }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
  end

  it 'refuses an unknown outcome' do
    expect { run!(outcome: 'maybe') }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'refuses a finish before its start' do
    expect do
      described_class.create!(name: 'x', started_at: Time.current, finished_at: 1.minute.ago, outcome: 'ok')
    end.to raise_error(ActiveRecord::StatementInvalid, /job_runs_finished_after_started/)
  end
end

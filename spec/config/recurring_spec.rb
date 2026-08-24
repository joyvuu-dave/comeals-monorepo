# frozen_string_literal: true

require 'rails_helper'
require 'fugit'

# config/recurring.yml is the production schedule. This pins that every
# entry names a job that exists and is a RecurringJob, that every schedule
# parses, and that the four jobs production depends on are there at the
# times the old Heroku Scheduler ran them.
RSpec.describe 'config/recurring.yml' do # -- a config file
  let(:tasks) { Rails.application.config_for(:recurring, env: 'production') }

  it 'names only jobs that exist and are recurring' do
    tasks.each_value do |task|
      next unless task[:class]

      expect(task[:class].constantize).to be < RecurringJob
    end
  end

  it 'has a schedule Fugit can parse, with an explicit zone, for every entry' do
    tasks.each do |key, task|
      cron = Fugit.parse(task[:schedule])
      expect(cron).not_to be_nil, "#{key} has an unparseable schedule"
      expect(cron.zone).to eq('UTC'), "#{key} has no zone; Fugit would read it in the process's local time"
    end
  end

  it 'keeps the four production jobs at their times (UTC)' do
    expected = {
      'refresh_balances' => ['RefreshBalancesJob', '0 3 * * * UTC'],
      'verify_ledger' => ['VerifyLedgerJob', '0 5 * * * UTC'],
      'set_multipliers' => ['SetMultipliersJob', '0 11 * * * UTC'],
      'ensure_rotations' => ['EnsureRotationsJob', '30 22 * * * UTC']
    }
    expected.each do |key, (klass, cron)|
      expect(tasks[key.to_sym][:class]).to eq(klass)
      expect(Fugit.parse(tasks[key.to_sym][:schedule]).to_cron_s).to eq(cron)
    end
  end

  it 'gives every recurring job a healthchecks.io slug' do
    RecurringJob.descendants.each do |job|
      expect(job::HEALTHCHECK).to be_present
    end
  end
end

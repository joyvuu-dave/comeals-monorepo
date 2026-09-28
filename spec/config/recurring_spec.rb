# frozen_string_literal: true

require 'rails_helper'
require 'fugit'

# config/recurring.yml is the production schedule. This pins that every
# entry names a job that exists and is a RecurringJob, that every schedule
# parses, and that the jobs production depends on are there at the
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

  it 'keeps the three production jobs at their times (UTC)' do
    expected = {
      'refresh_balances' => ['RefreshBalancesJob', '0 3 * * * UTC'],
      'verify_ledger' => ['VerifyLedgerJob', '0 5 * * * UTC'],
      'ensure_rotations' => ['EnsureRotationsJob', '30 22 * * * UTC']
    }
    expected.each do |key, (klass, cron)|
      expect(tasks[key.to_sym][:class]).to eq(klass)
      expect(Fugit.parse(tasks[key.to_sym][:schedule]).to_cron_s).to eq(cron)
    end
  end

  # Outside CI the test environment loads a class only when something uses
  # it, and descendants lists only loaded classes. So without eager loading
  # this example, run alone, checked an empty list, and it never saw a job
  # that is not on the schedule yet. Unnamed classes a spec builds are left
  # out.
  it 'gives every recurring job a healthchecks.io slug' do
    Rails.application.eager_load!
    jobs = RecurringJob.descendants.select(&:name)

    expect(jobs).to include(RefreshBalancesJob, VerifyLedgerJob, EnsureRotationsJob)
    jobs.each do |job|
      expect(job::HEALTHCHECK).to be_present, "#{job} has no healthchecks.io slug"
    end
  end

  # The base class raises NotImplementedError from its own `run`. This
  # keeps that from ever being the version that runs on the schedule.
  it 'names only jobs that define run themselves' do
    tasks.each_value do |task|
      next unless task[:class]

      job = task[:class].constantize
      expect(job.instance_method(:run).owner).to eq(job), "#{job} inherits run from #{job.instance_method(:run).owner}"
    end
  end
end

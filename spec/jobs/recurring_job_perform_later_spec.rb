# frozen_string_literal: true

require 'rails_helper'

# Every recurring job can be queued on Solid Queue itself, as production
# and the boot catch-up (RecurringCatchUp, config/initializers/solid_queue.rb)
# queue it.
#
# The rest of the suite queues jobs on the test adapter, which never
# computes a limits_concurrency key. Solid Queue computes it when the job
# is queued, and runs the key's block on the job, not on its class. Until
# 2026-10-20 RecurringJob's block called `name`, which a job does not
# have, so every queue of a recurring job raised NameError. On staging
# the boot catch-up raised it inside Puma and the web dyno crashed.
RSpec.describe RecurringJob, '.perform_later' do
  include_context 'with no test transaction'
  include_context 'with Solid Queue as the job adapter'

  let(:recurring_classes) do
    Rails.application.config_for(:recurring).values
         .filter_map { |task| task[:class]&.constantize }
         .select { |job_class| job_class < described_class }
  end

  it 'covers every job class in config/recurring.yml' do
    expect(recurring_classes.map(&:name))
      .to contain_exactly('RefreshBalancesJob', 'VerifyLedgerJob', 'EnsureRotationsJob', 'SendMissedSettlementMailJob')
  end

  it 'queues each one with a concurrency key named for its class' do
    recurring_classes.each(&:perform_later)

    keys = SolidQueue::Job.where(class_name: recurring_classes.map(&:name)).pluck(:class_name, :concurrency_key)
    expect(keys).to match_array(recurring_classes.map { |c| [c.name, "#{c.name}/#{c.name}"] })
  end

  it 'lets the boot catch-up queue every job that is due' do
    queued = RecurringCatchUp.call

    expect(queued).to match_array(recurring_classes)
    expect(SolidQueue::Job.where(class_name: recurring_classes.map(&:name)).count).to eq(recurring_classes.size)
  end
end

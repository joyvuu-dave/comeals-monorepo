# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The task is thin: bin/deploy, the weekly workflow and the staging
# rehearsal run it after a deploy. It raises through SolidQueueCheck,
# which is what makes the rake process exit non-zero and the deploy stop.
RSpec.describe 'deploy:verify_solid_queue' do
  before(:all) { RakeTasks.ensure_loaded }

  after { Rake::Task['deploy:verify_solid_queue'].reenable }

  it 'verify_solid_queue raises when no process has a heartbeat' do
    expect { Rake::Task['deploy:verify_solid_queue'].invoke }.to raise_error(/Solid Queue is not fully running/)
  end

  it 'verify_solid_queue passes and names the kinds when every one is alive' do
    SolidQueueCheck::PROCESS_KINDS.each do |kind|
      SolidQueue::Process.create!(kind: kind, last_heartbeat_at: Time.current, pid: 1, name: "#{kind}-1")
    end

    expect { Rake::Task['deploy:verify_solid_queue'].invoke }
      .to output(/Supervisor, Dispatcher, Worker, Scheduler are running/).to_stdout
  end

  describe 'deploy:verify_recurring_job' do
    after { Rake::Task['deploy:verify_recurring_job'].reenable }

    it 'raises when the scheduler has saved no task' do
      expect { Rake::Task['deploy:verify_recurring_job'].invoke }
        .to raise_error(/the scheduler has not saved its tasks/)
    end
  end
end

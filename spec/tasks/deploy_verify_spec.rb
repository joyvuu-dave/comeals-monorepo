# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The two deploy tasks are thin: the release phase runs the first, and
# bin/deploy and the weekly workflow run the second after the deploy.
# Each raises through DeployConfigCheck, which is what makes the rake
# process exit non-zero and the release or the deploy stop.
RSpec.describe 'deploy:verify_config and deploy:verify_solid_queue' do
  before(:all) { RakeTasks.ensure_loaded }

  after do
    Rake::Task['deploy:verify_config'].reenable
    Rake::Task['deploy:verify_solid_queue'].reenable
  end

  it 'verify_config passes outside production and says so' do
    expect { Rake::Task['deploy:verify_config'].invoke }
      .to output(/config vars this release needs are set/).to_stdout
  end

  it 'verify_config raises the missing vars in production' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:to_h).and_return({})

    expect { Rake::Task['deploy:verify_config'].invoke }.to raise_error(/SOLID_QUEUE_IN_PUMA=true/)
  end

  it 'verify_solid_queue raises when no process has a heartbeat' do
    expect { Rake::Task['deploy:verify_solid_queue'].invoke }.to raise_error(/Solid Queue is not fully running/)
  end

  it 'verify_solid_queue passes and names the kinds when every one is alive' do
    DeployConfigCheck::PROCESS_KINDS.each do |kind|
      SolidQueue::Process.create!(kind: kind, last_heartbeat_at: Time.current, pid: 1, name: "#{kind}-1")
    end

    expect { Rake::Task['deploy:verify_solid_queue'].invoke }
      .to output(/Supervisor, Dispatcher, Worker, Scheduler are running/).to_stdout
  end
end

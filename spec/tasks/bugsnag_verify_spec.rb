# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The task exists to prove the two paths to Bugsnag are connected, in
# production only. Anywhere else it must stop before sending anything.
RSpec.describe 'bugsnag:verify' do
  before(:all) { RakeTasks.ensure_loaded }

  after { Rake::Task['bugsnag:verify'].reenable }

  def run_task
    Rake::Task['bugsnag:verify'].invoke
  end

  it 'stops when no API key is set' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BUGSNAG_API_KEY').and_return(nil)

    expect { run_task }.to raise_error(SystemExit, /BUGSNAG_API_KEY is not set/)
  end

  it 'stops outside production, and says which environment it is in' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BUGSNAG_API_KEY').and_return('key')

    expect { run_task }.to raise_error(SystemExit, /nothing would be sent from test/)
  end

  it 'sends one error each way in production' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BUGSNAG_API_KEY').and_return('key')
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
    report = instance_double(Bugsnag::Report, :severity= => nil, add_tab: nil)
    allow(Bugsnag).to receive(:notify).and_yield(report)
    allow(Rails.error).to receive(:report)

    expect { run_task }.to output(/Sent two test errors/).to_stdout

    expect(Bugsnag).to have_received(:notify).with(an_instance_of(RuntimeError)).once
    expect(report).to have_received(:severity=).with('info')
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(RuntimeError), hash_including(handled: true, severity: :info))
  end
end

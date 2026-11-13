# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# rake test:faults hands the run to Faults::Session and stops with an
# error when the run found a problem. The run itself starts a PostgreSQL,
# a proxy and a Puma, so it is tested by a real run in
# spec/bin/faults_spec.rb; here it is replaced.
RSpec.describe 'test:faults', type: :task do
  let(:task) { Rake::Task['test:faults'] }
  let(:session) { instance_double(Faults::Session) }

  before(:all) { RakeTasks.ensure_loaded }

  before do
    task.reenable
    allow(Faults::Session).to receive(:new).and_return(session)
  end

  it 'runs one session with the environment and prints to standard output' do
    allow(session).to receive(:call).and_return(true)

    task.execute

    expect(Faults::Session).to have_received(:new).with(ENV, out: $stdout)
    expect(session).to have_received(:call).once
  end

  it 'stops with an error when the session found a problem' do
    allow(session).to receive(:call).and_return(false)

    expect { task.execute }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end

  it 'refuses to run outside the test environment' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { task.execute }.to raise_error(SystemExit).and output(/Must run in the test environment/).to_stderr
    expect(Faults::Session).not_to have_received(:new)
  end
end

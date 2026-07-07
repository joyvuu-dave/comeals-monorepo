# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require Rails.root.join('lib/clock_runner').to_s

RSpec.describe ClockRunner do
  # Each example gets its own Rake application so the tasks defined here
  # never touch the global one shared with the task specs.
  around do |example|
    original = Rake.application
    Rake.application = Rake::Application.new
    example.run
  ensure
    Rake.application = original
  end

  describe '.run_task' do
    it 'runs the task again on the next tick after a failure' do
      executions = 0
      Rake::Task.define_task('clock_spec:flaky') do
        executions += 1
        raise 'transient failure' if executions == 1
      end

      expect do
        described_class.run_task('clock_spec:flaky')
        described_class.run_task('clock_spec:flaky')
      end.to output(/FAILED/).to_stdout

      expect(executions).to eq(2)
    end

    it 'rescues a task failure and logs it instead of raising' do
      Rake::Task.define_task('clock_spec:boom') { raise 'kaboom' }
      allow(Rails.logger).to receive(:error)

      expect do
        described_class.run_task('clock_spec:boom')
      end.to output(/FAILED: clock_spec:boom -- kaboom/).to_stdout

      expect(Rails.logger).to have_received(:error)
        .with(/clock_spec:boom failed: RuntimeError: kaboom/)
    end

    it 'runs a succeeding task on every tick' do
      executions = 0
      Rake::Task.define_task('clock_spec:steady') { executions += 1 }

      described_class.run_task('clock_spec:steady')
      described_class.run_task('clock_spec:steady')

      expect(executions).to eq(2)
    end
  end
end

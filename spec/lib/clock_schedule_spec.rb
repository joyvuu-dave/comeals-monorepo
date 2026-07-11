# frozen_string_literal: true

require 'rails_helper'
require 'fugit'
require Rails.root.join('lib/clock_schedule').to_s

# The clock process (lib/clock.rb) runs ClockSchedule::TASKS unattended.
# A renamed rake task or a bad cron string would fail for the first time
# at 3am in production. These specs make it fail here instead.
RSpec.describe ClockSchedule do
  ClockSchedule::TASKS.each do |entry|
    describe "#{entry[:task]} (#{entry[:cron]})" do
      it 'names a rake task that exists' do
        RakeTasks.ensure_loaded
        expect(Rake::Task.task_defined?(entry[:task])).to be(true)
      end

      it 'has a cron expression the scheduler can parse' do
        expect(Fugit.parse_cron(entry[:cron])).not_to be_nil
      end
    end
  end
end

# frozen_string_literal: true

# rubocop:disable Rails/Output -- standalone clock process; stdout IS the log

$stdout.sync = true # Flush output immediately so foreman shows it in real time.

#
# Comeals Task Scheduler
#
# The schedule itself lives in lib/clock_schedule.rb (tested by
# spec/lib/clock_schedule_spec.rb). This file registers those tasks
# with a running scheduler.
# In production, these currently run via Heroku Scheduler.
# In development, start alongside the web server with: bin/dev
#
# Environment variables:
#   CLOCK_FAST    '1' runs all tasks every 2 minutes instead of their real
#                 schedule, so you can watch them fire during a dev session.
#                 Defaults to '1' in development and '0' everywhere else.
#                 Set CLOCK_FAST=0 to use the real schedules in development.
#

require_relative '../config/environment'
Rails.application.load_tasks

require_relative 'clock_runner'
require_relative 'clock_schedule'
require 'rufus-scheduler'

scheduler = Rufus::Scheduler.new

fast_mode = ENV.fetch('CLOCK_FAST') { Rails.env.development? ? '1' : '0' } == '1'

ClockSchedule::TASKS.each_with_index do |entry, i|
  if fast_mode
    # Stagger by 10s so tasks don't all fire simultaneously.
    scheduler.every '2m', first_in: "#{5 + (i * 10)}s" do
      ClockRunner.run_task(entry[:task])
    end
  else
    scheduler.cron entry[:cron] do
      ClockRunner.run_task(entry[:task])
    end
  end
end

# --- Boot Summary ----------------------------------------------------------

puts ''
puts '[clock] Comeals task scheduler started'
puts "[clock] Mode: #{fast_mode ? 'FAST (every 2 min)' : 'standard cron'}"
puts "[clock] #{ClockSchedule::TASKS.size} tasks registered:"
ClockSchedule::TASKS.each do |entry|
  schedule_display = fast_mode ? 'every 2m' : entry[:cron]
  puts format('[clock]   %-38<task>s %-14<schedule>s %<description>s',
              task: entry[:task], schedule: schedule_display, description: entry[:description])
end
if fast_mode
  puts '[clock]'
  puts '[clock] First batch fires in ~5 seconds.'
end
puts ''

scheduler.join

# rubocop:enable Rails/Output

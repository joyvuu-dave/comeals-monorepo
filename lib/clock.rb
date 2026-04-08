# frozen_string_literal: true

# rubocop:disable Rails/Output -- standalone clock process; stdout IS the log

$stdout.sync = true # Flush output immediately so foreman shows it in real time.

#
# Comeals Task Scheduler
#
# This file is the source of truth for all recurring tasks and when they run.
# In production, these currently run via Heroku Scheduler.
# In development, start alongside the web server with: bin/dev
#
# Environment variables:
#   CLOCK_FAST=1  Run all tasks every 2 minutes instead of their real schedule.
#                 Useful for observing tasks fire during a dev session.
#

require_relative '../config/environment'
Rails.application.load_tasks

require 'rufus-scheduler'

scheduler = Rufus::Scheduler.new

def run_task(name)
  started = Time.current
  puts "[clock] #{started.strftime('%H:%M:%S')} Starting: #{name}"

  Rake::Task[name].invoke
  Rake::Task[name].reenable

  elapsed = (Time.current - started).round(1)
  puts "[clock] #{Time.current.strftime('%H:%M:%S')} Finished: #{name} (#{elapsed}s)"
rescue StandardError => e
  puts "[clock] #{Time.current.strftime('%H:%M:%S')} FAILED:   #{name} -- #{e.message}"
  Rails.logger.error("[clock] #{name} failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
end

# --- Schedule Definition ---------------------------------------------------
#
# Cron expressions use the system's local timezone.
# Only billing:recalculate is currently active in Heroku Scheduler (daily 3am).
# The rest are run manually today but are included here as their natural cadence.
#
# Task                                | Cron          | When
# ------------------------------------|---------------|---------------------
# billing:recalculate                 | 0 3 * * *     | Daily 3:00am
# residents:set_multiplier            | 30 3 * * *    | Daily 3:30am
# community:create_rotations          | 0 4 * * *     | Daily 4:00am
# residents:notify                    | 0 7 * * 1     | Mondays 7:00am
# rotations:notify_new                | 15 7 * * *    | Daily 7:15am
#
# Manual tasks (not scheduled here -- run via `bundle exec rake <task>`):
#   reconciliations:create
#   reconciliations:send_cooking_slot_email
#   reconciliations:send_common_house_collection_email

SCHEDULED_TASKS = [
  { task: 'billing:recalculate',        cron: '0 3 * * *',  description: 'Refresh resident balances from source data' },
  { task: 'residents:set_multiplier',   cron: '30 3 * * *', description: 'Update multipliers based on resident age' },
  { task: 'community:create_rotations', cron: '0 4 * * *',  description: 'Ensure 6 months of meals exist' },
  { task: 'residents:notify',           cron: '0 7 * * 1',  description: 'Weekly rotation signup reminders' },
  { task: 'rotations:notify_new',       cron: '15 7 * * *', description: 'Notify residents of newly posted rotations' }
].freeze

fast_mode = ENV.fetch('CLOCK_FAST') { Rails.env.development? ? '1' : '0' } == '1'

SCHEDULED_TASKS.each_with_index do |entry, i|
  if fast_mode
    # Stagger by 10s so tasks don't all fire simultaneously.
    scheduler.every '2m', first_in: "#{5 + (i * 10)}s" do
      run_task(entry[:task])
    end
  else
    scheduler.cron entry[:cron] do
      run_task(entry[:task])
    end
  end
end

# --- Boot Summary ----------------------------------------------------------

puts ''
puts '[clock] Comeals task scheduler started'
puts "[clock] Mode: #{fast_mode ? 'FAST (every 2 min)' : 'standard cron'}"
puts "[clock] #{SCHEDULED_TASKS.size} tasks registered:"
SCHEDULED_TASKS.each do |entry|
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

# frozen_string_literal: true

# The clock process's schedule: which rake tasks recur and when.
#
# This table is the source of truth for all recurring tasks. lib/clock.rb
# reads it to register jobs. It lives in its own file so tests can load it
# without booting a scheduler: spec/lib/clock_schedule_spec.rb checks that
# every task name still exists in Rake and every cron expression parses.
#
# Cron expressions use the system's local timezone.
# Four tasks are active in Heroku Scheduler (which uses UTC):
# billing:recalculate at 03:00, residents:set_multiplier at 11:00,
# community:create_rotations at 22:30, and ledger:verify. The two notify
# tasks are gated off behind BROADCAST_EMAIL_ENABLED and have no Scheduler
# entry. Scheduled tasks ping healthchecks.io — see app/services/healthcheck.rb.
#
# ledger:verify must run after billing:recalculate, not before: a run that
# starts while balances are being rewritten is comparing against a moving
# target. Being a whole hour later is not what makes that safe — the snapshot
# in SnapshotRead is — but there is no reason to make them overlap.
#
# Manual tasks (not scheduled here -- run via `bundle exec rake <task>`):
#   reconciliations:create
#   reconciliations:send_cooking_slot_email
#   reconciliations:send_common_house_collection_email
module ClockSchedule
  TASKS = [
    { task: 'billing:recalculate', cron: '0 3 * * *', description: 'Refresh resident balances from source data' },
    { task: 'residents:set_multiplier', cron: '30 3 * * *', description: 'Update multipliers based on resident age' },
    { task: 'community:create_rotations', cron: '0 4 * * *', description: 'Ensure 6 months of meals exist' },
    { task: 'ledger:verify', cron: '0 5 * * *', description: 'Check settled balances against source data' },
    { task: 'residents:notify', cron: '0 7 * * 1', description: 'Weekly rotation signup reminders' },
    { task: 'rotations:notify_new', cron: '15 7 * * *', description: 'Notify residents of newly posted rotations' }
  ].freeze
end

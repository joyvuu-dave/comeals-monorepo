# Runbook: moving the schedule from Heroku Scheduler to Solid Queue

Written 2026-08-24, for the deploy that carries `config/recurring.yml`.
After this runbook has been followed once, the Heroku Scheduler add-on has
no jobs and can be removed; the schedule lives in git.

## What changes

- The four daily jobs (`RefreshBalancesJob` 03:00 UTC, `VerifyLedgerJob`
  05:00, `SetMultipliersJob` 11:00, `EnsureRotationsJob` 22:30) run from
  `config/recurring.yml`, by Solid Queue's supervisor inside the web dyno.
- Every run writes a `job_runs` row and pings the same healthchecks.io
  checks as before, so the "late" alerts keep working unchanged.
- `RecurringCatchUp` runs at Puma boot and enqueues any job that missed
  its last tick while the dyno was down.

## Steps

1. Deploy (`bin/deploy`). The migration creates Solid Queue's tables and
   `job_runs` in the primary database.
2. Set the config var that starts the supervisor inside Puma:
   `heroku config:set SOLID_QUEUE_IN_PUMA=true -a comeals-monorepo`.
   The dyno restarts; the log shows `SolidQueue-…: Started Supervisor`.
3. Confirm the catch-up ran: `heroku run rails runner 'puts JobRun.order(:id).last(4).map { |r| [r.name, r.outcome, r.finished_at] }'`.
   Every job that had never recorded a run is due at boot, so all four
   should have a row within a minute of the restart.
4. Leave both schedules running for one full day. Each healthchecks.io
   check should receive two pings per day (Scheduler's and Solid Queue's).
5. Delete the four jobs on the Heroku Scheduler dashboard
   (`https://dashboard.heroku.com/apps/comeals-monorepo/scheduler`).
6. The next day, confirm each check received exactly one ping, and that
   `job_runs` has one `ok` row per job.
7. Remove the add-on: `heroku addons:destroy scheduler -a comeals-monorepo`.

## If a job stops running

- `JobRun.where(name: 'refresh_balances').order(:id).last` — the last run
  and its outcome or error.
- `SolidQueue::FailedExecution.count` — jobs Solid Queue gave up on;
  each row holds the error.
- `SolidQueue::Process.all` — the supervisor, dispatcher, and worker
  should each have a recent `last_heartbeat_at`. None means the
  supervisor is not running: check `SOLID_QUEUE_IN_PUMA` is set.
- To run a job by hand: `heroku run rails runner 'RefreshBalancesJob.perform_now'`
  (or the old rake task, which is now the same thing).

## Moving to a worker dyno later

Add `worker: bin/jobs` to the `Procfile`, unset `SOLID_QUEUE_IN_PUMA`, and
scale the worker to one dyno. Nothing else changes.

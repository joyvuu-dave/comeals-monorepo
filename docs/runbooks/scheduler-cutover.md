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

Do not delete anything on the Scheduler dashboard until step 6. If Solid
Queue fails to start, the jobs still run from Scheduler while you fix it;
deleting first would leave the four jobs silently unrun until
healthchecks.io's grace period (1 hour) expires and emails you.

1. Deploy (`bin/deploy`). The migration creates Solid Queue's tables and
   `job_runs` in the primary database. Scheduler is still running the
   four jobs; nothing about them changes yet.
2. Raise the database pool before starting the supervisor, not after:
   `heroku config:set RAILS_DB_POOL=4 -a comeals-monorepo`. Today's pool
   of 2 is sized for one web request thread plus solid_cache's background
   trim thread (`config/database.yml` says so). The Puma plugin starts
   Solid Queue's supervisor, which forks the dispatcher, the scheduler,
   and the worker as separate processes. Each process gets its own pool
   of `RAILS_DB_POOL` connections, and each holds one open while it polls
   or runs a job. So the dyno goes from about 2 Postgres sessions to
   about 6 (web, trim thread, and one per Solid Queue process). A job
   that runs the solid_cache trim thread as well wants a second
   connection in its process; the pool of 4 leaves room for that. Check
   the Postgres plan's connection ceiling first (`heroku pg:info`) and
   count a one-off dyno on top; 6 is far under any Heroku Postgres plan's
   limit, but confirm before raising the pool further.
3. Set the config var that starts the supervisor inside Puma:
   `heroku config:set SOLID_QUEUE_IN_PUMA=true -a comeals-monorepo`.
   The dyno restarts; the log shows `SolidQueue-…: Started Supervisor`.
4. Confirm the catch-up ran: `heroku run rails runner 'puts JobRun.order(:id).last(4).map { |r| [r.name, r.outcome, r.finished_at] }'`.
   Every job that had never recorded a run is due at boot, so all four
   should have a row within a minute of the restart.
5. Leave both schedules running for one full day. Each healthchecks.io
   check should receive two pings per day (Scheduler's and Solid Queue's).
   The two can fire within seconds of each other at the shared UTC times;
   every job is idempotent, so a double run costs a few queries, not
   correctness — RefreshBalancesJob and VerifyLedgerJob recompute from
   source either way, SetMultipliersJob only moves a resident that is not
   already in the right band, and EnsureRotationsJob's own guard makes a
   second run a no-op once the calendar reaches six months out.
6. Delete the four jobs on the Heroku Scheduler dashboard
   (`https://dashboard.heroku.com/apps/comeals-monorepo/scheduler`).
7. The next day, confirm each check received exactly one ping, and that
   `job_runs` has one `ok` row per job.
8. Remove the add-on: `heroku addons:destroy scheduler -a comeals-monorepo`.

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

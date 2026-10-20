# Runbook: moving the schedule from Heroku Scheduler to Solid Queue

Written 2026-08-24, for the deploy that carries `config/recurring.yml`.
After this runbook has been followed once, the Heroku Scheduler add-on has
no jobs and can be removed; the schedule lives in git.

## What changes

- The three daily jobs (`RefreshBalancesJob` 03:00 UTC, `VerifyLedgerJob`
  05:00, `EnsureRotationsJob` 22:30) run from `config/recurring.yml`, by
  Solid Queue's supervisor on its own dyno, the worker in the `Procfile`
  (`worker: bin/jobs`). (`SetMultipliersJob` is
  gone since 2026-09-26: a resident's price band is computed from the
  birthday. Its Heroku Scheduler entry, `rake residents:set_multiplier`,
  and its healthchecks.io check, `residents-set-multiplier`, must be
  deleted at the deploy that carries that change, or the Scheduler entry
  fails every day and the check reports late. And if that release is ever
  rolled back, run the old release's `rake residents:set_multiplier` at
  once: the old code reads the `residents.multiplier` column, which the
  new code stops writing, so a child created or grown up after the
  deploy is priced wrong until that task runs.)
- A fourth daily job has no Scheduler entry, because it is new:
  `SendMissedSettlementMailJob` (16:00 UTC, healthchecks.io check
  `send-missed-settlement-mail`, created by its first ping). It queues
  the cook mail again for each settlement from the last 7 days that still
  has a cook without it, and the common house mail for each that has not
  sent it. It reports to Bugsnag a settlement that reaches 7 days with a
  mail still not sent. It leaves alone every settlement
  made before its own first run, which happens when the supervisor first
  starts (step 4): those
  were mailed before the app kept a record of each mail.
- Every run writes a `job_runs` row and pings the same healthchecks.io
  checks as before, so the "late" alerts keep working unchanged.
- `RecurringCatchUp` runs once each time the supervisor starts (its start
  hook, `config/initializers/solid_queue.rb`) and enqueues any job that
  missed its last tick while the worker dyno was down.

## The deploy does steps 1 to 3 itself

The Procfile's release phase runs `rake deploy:verify_config` before the
migration. On production it refuses the release when `RAILS_DB_POOL` is
under 4, so Heroku keeps the previous release serving; the message names
the exact `heroku config:set` to run. `bin/deploy` and the weekly
workflow both set the pool before they push or promote when production
lacks it. Both scale the worker dyno to 1 after the release, and then
run `rake deploy:verify_solid_queue`, which fails unless the supervisor,
dispatcher, worker and scheduler all have a heartbeat from the last two
minutes. `bin/deploy` stops on that; the workflow rolls back. Staging is
exempt from the config check (`COMEALS_STAGING`): `bin/staging-rehearsal`
sets the pool there itself, runs the worker dyno during the rehearsal
(staging is neutered, so its jobs send nothing out), checks the same
heartbeats, and parks both dynos at the end. The steps below are still
the record of what happens and why.

## Steps

Do not delete anything on the Scheduler dashboard until step 6. If Solid
Queue fails to start, the jobs still run from Scheduler while you fix it;
deleting first would mean the jobs do not run, and nothing tells you,
until healthchecks.io's grace period (1 hour) ends and it emails you.

1. Raise the database pool before the deploy:
   `heroku config:set RAILS_DB_POOL=4 -a comeals-monorepo`. (`bin/deploy`
   sets it too when it is missing, after its question and before the
   backup.) The pool of 2 was sized for one web request thread plus
   solid_cache's background trim thread (`config/database.yml` says so).
   The worker dyno runs Solid Queue's supervisor, which forks the
   dispatcher, the scheduler and the worker as separate processes. Each
   of the four processes has its own pool of `RAILS_DB_POOL` connections
   and uses more than one at once: the poll or the main loop, the
   heartbeat thread, a running job, and the trim thread when a job
   writes to the cache. The connection count is in "Database
   connections" below.
2. Deploy (`bin/deploy`). The migration creates Solid Queue's tables and
   `job_runs` in the primary database. The release adds the `worker`
   process type, and `bin/deploy` scales it to 1 after the cache clear
   and the balance recalculation. Scheduler is still running the jobs
   too; that is step 5.
3. Check the worker dyno: `heroku ps -a comeals-monorepo` lists
   `worker.1` as up, and `heroku logs -a comeals-monorepo --dyno worker`
   shows `SolidQueue-1.7.0 Started Supervisor(fork)` (the number is the
   solid_queue version). `bin/deploy` has already run
   `rake deploy:verify_solid_queue`.
4. Confirm the catch-up ran: `heroku run rails runner 'puts JobRun.order(:id).last(4).map { |r| [r.name, r.outcome, r.finished_at] }'`.
   Every job that had never recorded a run is due when the supervisor
   starts, so all four should have a row within a minute of it.
   `RefreshBalancesJob` may already have one from the deploy's own
   `billing:recalculate`, which runs the same job before the worker
   starts.
5. Leave both schedules running for one full day. Each healthchecks.io
   check should receive two pings per day (Scheduler's and Solid Queue's),
   except `send-missed-settlement-mail`, which only Solid Queue runs.
   The two can fire within seconds of each other at the shared UTC times;
   every job is idempotent, so a double run costs a few queries, not
   correctness — RefreshBalancesJob and VerifyLedgerJob recompute from
   source either way, and EnsureRotationsJob's own guard makes a second
   run a no-op once the calendar reaches six months out.
6. Delete the jobs on the Heroku Scheduler dashboard
   (`https://dashboard.heroku.com/apps/comeals-monorepo/scheduler`).
7. The next day, confirm each check received exactly one ping, and that
   `job_runs` has one `ok` row per job.
8. Remove the add-on: `heroku addons:destroy scheduler -a comeals-monorepo`.

## Live updates depend on the supervisor too

Since 2026-09-15 every push to Pusher is a `LivePushJob` (ADR 0007). If
the supervisor is not running, writes still commit and the calendar
cache still clears, but no open screen is told to refetch until it
reconnects. So the worker dyno must run from the deploy that carries
this change on. A quick check after a deploy: change a meal's
description in admin and watch an open calendar tab refresh.

## If a job stops running

- `JobRun.where(name: 'refresh_balances').order(:id).last` — the last run
  and its outcome or error.
- `SolidQueue::FailedExecution.count` — jobs Solid Queue gave up on;
  each row holds the error.
- `SolidQueue::Process.all` — the supervisor, dispatcher, worker and
  scheduler should each have a recent `last_heartbeat_at`. None means
  the supervisor is not running: check that the worker dyno runs
  (`heroku ps -a comeals-monorepo`; start it with
  `heroku ps:scale worker=1 -a comeals-monorepo`) and read its log
  (`heroku logs -a comeals-monorepo --dyno worker`).
- To run a job by hand: `heroku run rails runner 'RefreshBalancesJob.perform_now'`
  (or the old rake task, which is now the same thing).

## Database connections

Heroku Postgres essential-1 allows 20 connections. A process opens a
connection only when one of its threads needs one, so the pool size
(`RAILS_DB_POOL=4`) is a limit for each process, not a count.

| Process                                           | Usual | Threads allow | Pools allow |
| ------------------------------------------------- | ----- | ------------- | ----------- |
| Web dyno: one Puma thread, the trim thread        | 1–2   | 2             | 4           |
| Worker dyno: supervisor and three forks           | 5–7   | about 13      | 16          |
| One-off `heroku run` (a rake task, a console)     | 1–2   | 2             | 4           |
| Release phase (`deploy:verify_config db:migrate`) | 1–2   | 2             | 4           |
| All at once                                       | ~13   | ~19           | 28          |

The worker dyno's 5 is measured: `bin/jobs` with this `config/queue.yml`
held 5 idle connections for its 4 processes. A running job adds one,
and one more when it writes to the cache. Each Solid Queue process has
three or four threads that can use the database at once (the main loop,
the heartbeat, a job, a timer), which gives the 13.

The closest a real moment comes to 20 is a push deploy. Heroku restarts
both dynos, and an old dyno can take up to 30 seconds to stop while the
new one boots, so for that time there can be two worker dynos (about 7
each) and two web dynos (about 2 each), and `bin/deploy` starts its
cache clear in a one-off dyno right then: about 20. A maintenance deploy
does not have this, because web and the worker are at 0 while the
release and the one-off dynos run. If the logs ever show `too many
connections`, the choices are a plan with more connections, PgBouncer,
or a smaller pool for the worker dyno alone, set in its Procfile line.

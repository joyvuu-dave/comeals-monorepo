# Runbook: moving the schedule from Heroku Scheduler to Solid Queue

Written 2026-08-24, for the deploy that carries `config/recurring.yml`.
After this runbook has been followed once, the Heroku Scheduler add-on has
no jobs and can be removed; the schedule lives in git.

## What changes

- The three daily jobs (`RefreshBalancesJob` 03:00 UTC, `VerifyLedgerJob`
  05:00, `EnsureRotationsJob` 22:30) run from `config/recurring.yml`, by
  Solid Queue's supervisor on its own dyno, the worker in the `Procfile`
  (`worker: env RAILS_DB_POOL=12 bin/jobs --mode async`). (`SetMultipliersJob` is
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
  starts (step 3): those
  were mailed before the app kept a record of each mail.
- Every run writes a `job_runs` row and pings the same healthchecks.io
  checks as before, so the "late" alerts keep working unchanged.
- `RecurringCatchUp` runs once each time the supervisor starts (its start
  hook, `config/initializers/solid_queue.rb`) and enqueues any job that
  missed its last tick while the worker dyno was down.

## The deploy does steps 1 and 2 itself

`bin/deploy` and the weekly workflow both scale the worker dyno to 1
after the release, and then run `rake deploy:verify_solid_queue`, which
fails unless the supervisor, dispatcher, worker and scheduler all have a
heartbeat from the last two minutes, and then
`rake deploy:verify_recurring_job`, which queues the hourly
`delete_expired_guest_add_keys` task the way the scheduler does and
fails unless the worker has run it within two minutes. `bin/deploy`
stops on either. The workflow rolls back the code only if the release
ran no migration; if it ran one, the run fails and production stays as
it is (`docs/runbooks/undo-a-deploy.md`). `bin/staging-rehearsal` runs
the worker dyno during the rehearsal too (staging is neutered, so its
jobs send nothing out), runs the same two checks, and parks both dynos
at the end. The steps
below are still the record of what happens and why.

## Steps

Do not delete anything on the Scheduler dashboard until step 5. If Solid
Queue fails to start, the jobs still run from Scheduler while you fix it;
deleting first would mean the jobs do not run, and nothing tells you,
until healthchecks.io's grace period (1 hour) ends and it emails you.

1. Deploy (`bin/deploy`). The migration creates Solid Queue's tables and
   `job_runs` in the primary database. The release adds the `worker`
   process type, and `bin/deploy` scales it to 1 after the cache clear
   and the balance recalculation. Scheduler is still running the jobs
   too; that is step 4.
2. Check the worker dyno: `heroku ps -a comeals-monorepo` lists
   `worker.1` as up, and `heroku logs -a comeals-monorepo --dyno worker`
   shows `SolidQueue-1.7.0 Started Supervisor(async)` (the number is the
   solid_queue version). `bin/deploy` has already run
   `rake deploy:verify_solid_queue`.
3. Confirm the catch-up ran: `heroku run rails runner 'puts JobRun.order(:id).last(4).map { |r| [r.name, r.outcome, r.finished_at] }'`.
   Every job that had never recorded a run is due when the supervisor
   starts, so all four should have a row within a minute of it.
   `RefreshBalancesJob` may already have one from the deploy's own
   `billing:recalculate`, which runs the same job before the worker
   starts.
4. Leave both schedules running for one full day. Each healthchecks.io
   check should receive two pings per day (Scheduler's and Solid Queue's),
   except `send-missed-settlement-mail`, which only Solid Queue runs.
   The two can fire within seconds of each other at the shared UTC times;
   every job is idempotent, so a double run costs a few queries, not
   correctness — RefreshBalancesJob and VerifyLedgerJob recompute from
   source either way, and EnsureRotationsJob's own guard makes a second
   run a no-op once the calendar reaches six months out.
5. Delete the jobs on the Heroku Scheduler dashboard
   (`https://dashboard.heroku.com/apps/comeals-monorepo/scheduler`).
6. The next day, confirm each check received exactly one ping, and that
   `job_runs` has one `ok` row per job.
7. Remove the add-on: `heroku addons:destroy scheduler -a comeals-monorepo`.

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
connection only when one of its threads needs one, so a pool is a limit
for each process, not a count. Production sets no `RAILS_DB_POOL`
config var:

- Web, one-off dynos and the release phase use `config/database.yml`'s
  default of 2: the request thread (or the task) and solid_cache's trim
  thread. `DatabasePoolCheck` refuses to boot a process whose pool is
  smaller than its threads plus that one.
- The worker dyno's line in the Procfile is `env RAILS_DB_POOL=12
bin/jobs --mode async`. In async mode the supervisor runs the
  dispatcher, the worker and the scheduler as threads of its one
  process, so they share one pool of 12: one for each thread that can
  hold a connection at the same moment (the supervisor 3, the dispatcher
  3, the worker 3 for `threads: 1`, the scheduler 2, solid_cache's trim
  thread 1). `spec/config/procfile_spec.rb` counts them from the gem's
  code and the two config files, and fails if they ever need more than
  the Procfile gives.

| Process                                       | Usual | Pools full |
| --------------------------------------------- | ----- | ---------- |
| Web dyno                                      | 1–2   | 2          |
| Worker dyno: one process, pool of 12          | 5–6   | 12         |
| One-off `heroku run` (a rake task, a console) | 1–2   | 2          |
| Release phase (`bin/rake db:migrate`)         | 1–2   | 2          |
| All at once                                   | ~6–10 | 18         |

The worker dyno held 5 idle connections when run locally, and staging
peaked at 6 in all. A restart does not add to this: Heroku stops the old
web and worker dynos before it starts the new ones (no preboot; checked
on staging). Each further one-off dyno running at the same time (a
second console, say) adds up to 2, so two of them with everything else
full would make 20.

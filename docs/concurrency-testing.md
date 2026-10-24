# Concurrency testing

How this app is tested for what happens when many things run at once, and
what each test is for. The ideas come from
[Rails thread safety](https://pawelurbanek.com/rails-thread-safety): state
on a class or a thread is shared between requests; a read followed by a
write can lose an update; and the way to find both is to hit a real app
with many requests at the same time and check every answer.

Production runs Puma with one thread (`config/puma.rb`). These tests run
many on purpose: one thread hides every bug of this kind, and the other
processes production does have (a rake task in its own dyno, the jobs on
the worker dyno, an admin in a browser) are enough to trigger some of them
(ADR 0003).

## The four layers

### 1. No process-wide mutable state — `spec/concurrency/process_wide_state_spec.rb`

Reads every file under `app/`, `lib/` and `config/initializers/` with Prism
and refuses class variables (`@@x`), `Thread.current`, and instance
variables written on a class (`@x ||=` inside `def self.` or `class <<
self`). One memo is allowed, `JwtAuth.secret`, because two threads that
race it derive the same bytes. `Current` (CurrentAttributes) is the one
allowed thread-local, because layer 2 proves Rails resets it.

The `rubocop-thread_safety` cops run in `bin/check`'s RuboCop step beside
this scan (added 2026-09-13). They read the same files for four things
the scan does not: a write to a `cattr_accessor`, `mattr_accessor` or
`class_attribute`; a mutable object (an array, a hash, a string) held in
a class instance variable; `Dir.chdir`; and an instance variable set in
a Rack middleware's `call`. On the day they were added they found
nothing the scan had not (the `JwtAuth.secret` memo, and the mutant
worker's own session id in `config/mutant/hooks.rb`, each marked with
its reason). Their `NewThread` cop is off under `spec/`, where the
concurrency specs start threads on purpose.

### 2. Nothing leaks across a reused thread — `spec/concurrency/recycled_thread_spec.rb`

Four threads, sixty requests each, through the whole Rack stack in one
process, every request setting something in `Current` (the socket id, the
community, the resident names), and a job run between them the way Solid
Queue runs it. A probe at the start of every request and job must see an
empty `Current` and no open transaction. Then the app-visible checks: every
meal push carries exactly the socket id of the request that wrote it, and
a resident renamed between two requests on one thread is shortened under
the new name in the second.

### 3. The in-process storm — `spec/concurrency/request_storm_spec.rb`

Runs in `bin/check`. Many client threads (24 by default) send random
requests from the whole API through the Rack stack for 15 seconds, while
a settler, the nightly jobs, and an admin writing through the models
the way ActiveAdmin does run beside them. The admin takes no
`with_meal_lock`, but the models take the meal's `FOR KEY SHARE` lock
first (`LocksItsMealFirst`), and attendance is marked as an admin
correction, as the admin form marks it. `Rails.cache` and the Rack::Attack
counters are a real solid_cache in the test database, at SERIALIZABLE,
like production. One difference: the test environment leaves DEFERRABLE
out of `SnapshotRead` (`config/environments/test.rb`), so the balance
refresh and the ledger check can fail with a serialization error there
and be retried. Production's cannot. What must hold:

- every answer is one the API promises for that action, never a 500;
- every answer belongs to its request (`/residents/id`, the login);
- every 429 had grounds: the client counts its own requests per throttle
  window, so a 429 under the limit means the counter held someone else's;
- every meal push carries a socket id that was sent with a write to that
  meal;
- every error the app reported and swallowed is a conflict;
- the settler, the jobs, and the admin hit nothing but their expected
  refusals;
- the rows and the ledger are right after (`Storm::Checks`): every meal
  agrees with the plain ledger, a settled meal's stored charges equal its
  final rows, a settled meal with someone charged has no blank cost,
  `ledger:verify` passes, a cap holds, the balance refresh is
  stable, and every calendar month reads the same with the cache and
  without it;
- the storm happened: meal writes were sent at a quarter or more of
  the rate one client alone gets on the same machine, every client sent
  at least one, rows were written under them (attendance, guests,
  bills: one every three seconds at least; the runner writes about
  forty in fifteen seconds, a laptop hundreds, a run where every write
  conflicts none), and a settlement won while they did. Each floor
  follows what its count depends on, so `STORM_CLIENTS` and
  `STORM_SECONDS` can turn the storm up. The floor used to be five ok
  writes per client in total, a laptop's number, and the CI runner
  missed it twice (#86).

The rate floor is measured, not fixed (#131). A fixed eight writes a
second failed whenever other test suites loaded the laptop. So
`Storm::Baseline` has one client sign up for a meal of its own and
leave it again, alone, for two seconds just before the storm and again
just after it, and the floor is a quarter of the slower of the two. The
GVL runs one request's Ruby at a time, so the 24 clients together send
about half as many meal writes a second as one client alone (half their
requests are not meal writes): 0.44 to 0.70 of it on a laptop, and 0.79
or more with the laptop made busy. The floor catches a storm in which
nearly every client is waiting at once: a settlement that locked the
meals table and then waited five seconds brought the storm to 8 to 10
writes a second, under floors of 15 to 18. Waits that stop only some
clients do not show, because the others use the time, and neither does
a write that got slower for everyone, since one client alone slows down
as much. These left the rate where it was: every API request behind
one mutex, every meal write behind one database lock, a 50 ms sleep
inside the meal lock, and a one-second wait before each retry after a
conflict. The GVL already runs one request's Ruby at a time.

One client alone still gets 409s while a SERIALIZABLE transaction that
has written something stays open in another database on the same
Postgres server, such as another worktree's test run (#218). PostgreSQL
keeps a record of each SERIALIZABLE transaction that committed after
that one started. When the space for those records is full, it keeps
only a summary of the oldest, and then it refuses writes it can no
longer prove safe ("Canceled on identification as a pivot, during
write"). So `Storm::Baseline` and the reused-thread spec send a
refused write again every 0.1 to 0.2 seconds for up to 30 seconds
(`Storm::Refusals`), and when they give up they list the open
transactions on the server that have written something.

A settlement always has something to claim: the seed plants a meal 14
days back, the newest a settlement may cover (ADR 0011 rule 2), with a
cook who spent money and a guest who pays (#131). Before, the settler
waited for a client's bills save to go through on a past meal, and on a
busy machine most of those end in 409. Clients leave a cost blank on the
other meals now and then, and the checks refuse a settled meal with a
blank cost and someone to charge (ADR 0011 rule 3): a settlement that
claimed a meal on an old read, while a cook cleared a cost, would show
there.

Knobs: `STORM_SECONDS`, `STORM_CLIENTS`, `STORM_SEED`, and `STORM_TALLY=1`
to print the counts. The pool is widened for the group; Postgres allows
100 connections by default.

The client, the runner, and the checks live in `spec/support/storm/` and
speak only HTTP through a transport, so the same code drives layer 4.

### 4. The real-server storm — `bin/storm`

Not in `bin/check`. Boots a Puma from this checkout with many threads and
workers (16 x 2 by default) on this worktree's test port, with solid_cache
as its store, and runs `rake test:storm`: the same clients over TCP (64 by
default, each with its own forwarded IP), the settler, the jobs, and the
admin from the driver process, and the same checks after. This is the one
that runs real sockets, real Puma threads, and a forking server.

    bin/storm
    STORM_THREADS=32 STORM_WORKERS=4 STORM_CLIENTS=128 STORM_SECONDS=60 bin/storm
    STORM_POOL=2 bin/storm          # stops at boot: the pool is smaller than the threads + 1

Read `tmp/storm_server.log` after a run; the script prints its error
lines.

Every process of the storm (the server, the storm task, and the jobs
process below) writes what it reports through `Rails.error` to
`tmp/storm_errors.log` (`Storm::ErrorLog`). The run fails on a report
that is not a conflict, on a job that could not be queued after its
retries, and on an error the jobs process raised. The in-process storm
checks the same thing with a subscriber in the spec.

#### The jobs through a real Solid Queue — `STORM_SOLID_QUEUE=1`

By default the server uses the test queue adapter and the storm task
runs the nightly jobs in its own process, so no job is ever a
`solid_queue_*` row. With `STORM_SOLID_QUEUE=1` the server and the
storm task queue every job in Solid Queue in the test database, and
the storm task starts a real `bin/jobs --mode async` with a pool of 12
once the seed is in (`Storm::JobsProcess`; log in `tmp/storm_jobs.log`).
It starts after the seed because Solid Queue's start hook
(`RecurringCatchUp`) queues every nightly job, and those need the
community. Every push, every settlement mail and every recurring job is
then a row that a real worker claims, under semaphores and heartbeats,
beside the app's SERIALIZABLE writes. Pusher is a no-op and mail goes to
the test delivery method.

The processes and threads are production's (one dispatcher, one worker
with one thread, the scheduler). The intervals are made short so their
bookkeeping meets the app's writes as often as possible:
`spec/support/storm/queue.yml` polls every 0.1 s and runs concurrency
maintenance every second, and `spec/support/storm/recurring.yml.erb` runs
every recurring task every 7 s, each at its own second, so the pool of
12 still holds. The storm task's job loop still runs the nightly jobs
in its own process and now also queues them: a run here takes no
semaphore, so it overlaps the worker's run of the same job, while the
queued one goes through the semaphore and the blocked list.

After the storm, `Storm::QueueChecks` waits for every job queued before
the end to finish (`STORM_SQ_DRAIN`, 300 s), checks the queue with the
jobs process running, stops it with TERM the way Heroku does, and
checks again. The run fails on a failed job, a job claimed by a process
that is gone, a heartbeat older than the alive threshold, an error line
in the jobs log (a conflict, a deadlock, "Error in thread", "Error
performing"), a jobs process that died or exited with an error, or a
process row left after the stop.

    STORM_SOLID_QUEUE=1 bin/storm
    STORM_SOLID_QUEUE=1 STORM_SQ_HEARTBEAT=1 bin/storm      # beat every second (production: 60)
    STORM_SOLID_QUEUE=1 STORM_JOBS_PROCESSES=2 bin/storm    # two supervisors, as during a deploy

Count the connections before turning the dial: the server takes
workers x pool, each jobs process 12, the storm task 12, and psql one.
Postgres allows 100 by default and keeps 3 of them for superusers.

Every run also reports how long the requests took, from the client's
side: p50, p95, p99 and the slowest, per action and overall, and the
requests per second the run sustained. Percentiles rather than an
average, because the slow tail is what a person notices. The numbers
are this machine's, so a run saves them to `tmp/storm_latency.json`
under its shape (clients and seconds), and the next run of the same
shape prints the change against them. `STORM_MAX_P95=<ms>` turns the
p95 into a check that fails the run. The in-process storm prints the
same report under `STORM_TALLY=1`. What one laptop showed on
2026-09-12, 32 clients for 15 seconds against 16 threads x 2 workers:
about 290 requests a second, p50 83 ms, p95 280 ms, slowest 650 ms —
a baseline for this machine, not a promise about a dyno.

## What the storms found (2026-09-11)

The first three, each fixed the same day with a deterministic spec.

- A meal write refused once for a conflict and retried answered 500. The
  first attempt had assigned the new values to the meal, and `with_lock`
  refuses a record with unsaved changes. Now each attempt drops them first
  (`Api::V1::MealsController#with_meal_lock`,
  `spec/requests/api/v1/meal_write_retry_spec.rb`).
- The calendar writes (events, guest room and common house reservations)
  had no retry and no rescue for a serialization failure, so a reservation
  racing another answered 500. Now they retry and answer 409
  (`ApiController#render_retrying_on_conflict`,
  `spec/requests/api/v1/calendar_writes_retry_spec.rb`).
- A nightly job refused for a conflict failed outright, with a failed run
  record and a fail ping. `EnsureRotationsJob` conflicted in seven of eight
  runs under the storm; two balance refreshes at once conflict too. Now
  `RecurringJob` retries the run, and `SettleAndNotify` retries the balance
  refresh after a settlement and reports one that keeps failing instead of
  raising about a settlement that is already in the database
  (`spec/jobs/recurring_job_spec.rb`, `spec/services/settle_and_notify_spec.rb`).

Three more, found while fixing those:

- An admin write and an API write on one meal deadlocked. The API locks
  the meal row and then the child row; an admin write had no meal lock of
  its own, so it wrote the child row first and the settled-meal trigger
  then asked for the meal from inside that write — the opposite order.
  PostgreSQL broke it after a second and one side was told to try again.
  Now every child row locks its meal before it writes itself
  (`LocksItsMealFirst`), so both paths lock meal first, row second
  (`spec/requests/admin/meal_lock_order_spec.rb`). The admin write then
  waits for the API's write and is told to try again, because the API's
  write changed the meal row; it never deadlocks.
- The calendar read answered 500 when PostgreSQL refused it. A read can
  be refused at SERIALIZABLE too, and the calendar month reads nine
  tables and then writes a cache entry, which makes it a likely pick. It
  is rebuilt now, and anything that still escapes — a conflict in a
  `before_action` or in any read — is answered 409 by `ApiController`
  instead of 500 (`spec/requests/api/v1/calendar_read_conflict_spec.rb`). This one
  predates the branch; the storm finds it about one run in three.
- The settlement rake task exited 1 when a reconciler settled from the
  app at the same moment and claimed the meals first. That is a period settled by someone else, not a failure,
  so it is logged and skipped like an empty period.

Three more, from the runs at 128 to 256 clients:

- A pool smaller than the thread count answered 500
  (`ActiveRecord::ConnectionTimeoutError`). The two settings are separate
  on purpose (`config/database.yml`), which is what makes it easy to raise
  the threads and leave the pool behind. Now the app refuses to boot on
  that configuration at all (`DatabasePoolCheck`, one connection per
  thread plus one for solid_cache's trim thread), and a checkout that
  times out for any other reason answers 503 with a `Retry-After` rather
  than 500, on both halves of the app
  (`spec/lib/database_pool_check_spec.rb`,
  `spec/requests/api/v1/pool_exhaustion_spec.rb`,
  `spec/requests/admin/pool_exhaustion_spec.rb`).

- The settle button used the rake task's patience. Both web callers,
  the API endpoint and the admin form, went through the same entry point
  as the rake task, which tries ten times with the delay doubling from a
  quarter second — two to four minutes of sleeping before it gives up.
  The web dyno serves one request at a time, so a contested settlement
  held the only thread and stopped the app for everyone, while Heroku's
  router gave up at 30 seconds and showed the reconciler an error for a
  settlement that was still running. The caller picks now:
  `SettleAndNotify::BATCH` for the rake task, `::REQUEST` for a person
  — three quick tries, then the 409 the controller already had
  (`spec/requests/api/v1/reconciliations_create_spec.rb`).
- The admin settle form answered 500 for `Settlement::Contested`. Nothing
  rescued it: RetryOnConflict retries only a refusal from the database,
  and the admin conflict rescue catches ActiveRecord errors, which this
  is not. It shows the same try-again message now
  (`spec/requests/admin/reconciliation_immutability_spec.rb`).

Two things the storms show that are not bugs. Routes are drawn lazily in
the test environment, on the first request, and many first requests at
once race that. Production eager loads, so the storm specs eager load
too.

A third, in the reused-thread spec (layer 2): four threads that write at
the same instant conflict at SERIALIZABLE even on different meals,
because the test tables are small enough that every row shares a page
and the predicate locks overlap. A write whose three tries all conflict
answers 409, by design, and under a loaded laptop that happened to one
thread's first signup (2026-09-12). The spec now does what a client
does, tries a 409 again, and raises on any other answer than 200, so a
request that did not happen is reported as that and not as a push that
never came.

## What the database races found (2026-10-16)

Beside the storms, `spec/db/` races one write against another on two
sessions, in the exact order that causes the race (`settlement_race_spec.rb`,
`dinner_cancelling_race_spec.rb`, `no_cost_marking_race_spec.rb`), and
runs a storm of writers against one meal while it is settled
(`meal_write_storm_spec.rb`, which since 2026-10-16 also cancels and
restores the dinner). A bug hunt found a case none of them covered: a
write from psql, at READ COMMITTED, that starts before a settlement or a
cancel and changes only rows that the settlement or the cancel reads,
not rows it writes. (In the No cost race both sides write the same
bill, and in the dinner cancelling race the cook writes through the
models, whose `touch: true` changes the meal row; both end in a
conflict.) The settlement or the cancel waited for it at its `FOR UPDATE`,
but at SERIALIZABLE its snapshot was taken before the wait. The trigger
only read the meal row `FOR KEY SHARE`, a lock changes no row, and
PostgreSQL's conflict check does not see a READ COMMITTED writer, so
after the wait it decided from the rows as they were: a settlement
without a sign-up added at that moment, and a dinner cancelled with a
cost of $12 on it. Now the trigger updates the meal row
(`updated_at = updated_at`, in `comeals_reject_settled_child_write`), so the waiting
transaction fails as a conflict and is tried again with a fresh
snapshot (`settlement_after_a_raw_write_race_spec.rb`,
`cancel_against_a_cost_race_spec.rb`; ADR 0003, "The other order").

## What the Solid Queue storm found (2026-10-20)

The first runs of `STORM_SOLID_QUEUE=1`, on the jobs-dyno branch, on
PostgreSQL 16 and 18. Each one got a failing spec, and all three were
fixed the same evening.

- Four steps that `config/initializers/solid_queue_isolation.rb` wrapped
  at READ COMMITTED raised `TransactionIsolationError` whenever they
  opened a savepoint, because the wrapper gave its level to every
  transaction opened inside it, savepoints too: the scheduler queueing a
  recurring task (on every tick; staging showed the same error at every
  tick while every heartbeat was fresh), a worker deregistering with a
  job claimed, the worker recording a job that raised (the job stayed
  claimed and held its semaphore), and the dispatcher moving a due job
  with a concurrency limit to ready
  (`spec/config/initializers/solid_queue_isolation_savepoint_spec.rb`).
- The UPDATE that gives a finished job's semaphore back ran outside any
  transaction, so at the session's SERIALIZABLE, and PostgreSQL refused
  it under load. The job was finished, but the semaphore was not given
  back, so the next run of that job waited up to an hour. At 128 clients
  on PostgreSQL 18 this left 350 to 430 recurring jobs blocked (same
  spec file).
- `RecurringCatchUp` did not try a conflict again. Two supervisors
  starting at once conflicted on each job's semaphore row, and neither
  queued the job (`spec/services/recurring_catch_up_spec.rb`).

The fix for the first two: each step on the initializer's list, when
called with no transaction open, now runs in one explicit READ
COMMITTED transaction, and the semaphore give-back is on the list (ADR
0005 decision 10 has the details and what stays at SERIALIZABLE).
`RecurringCatchUp` now retries with `RetryOnConflict`. And because the
heartbeat check passed on staging while the scheduler failed,
`rake deploy:verify_recurring_job` now queues a recurring task the way
the scheduler does and waits for the worker to run it, in `bin/deploy`,
the staging rehearsal and the Deploy workflow.

Runs after the fix, 2026-10-20: the default shape, a 1 s heartbeat,
and two jobs processes, three times each on PostgreSQL 16 and 18, then
128 clients for 60 s twice on each. No `TransactionIsolationError`, no
conflict line from Solid Queue's own work in any jobs log, and every
queue drained with no claim left. The runs that failed, failed only on
the limits below, and on one more line: with two jobs processes, the
first try of a catch-up enqueue conflicts and Active Job logs "Failed
enqueuing" for it, though the retry then queues the job.

Two things the storm shows that are limits, not failing specs: a push
whose enqueue conflicts three times in a row is lost (0 to 4 in a
20 to 60 second run, 7 to 28 at 128 clients), and `EnsureRotationsJob`
uses up its five tries in most runs and ends as a failed job. At 256
clients for 300 seconds, and on PostgreSQL 16 at 128 clients for 120
seconds, the server runs out of shared memory for its SSI locks
(`max_pred_locks_per_transaction`); without Solid Queue the same 256
clients do not, but the laptop is already past its limit there (p95
5.6 s).

Both limits were kept as they are on purpose (decided 2026-10-20), so a
storm run that fails only on them is not a new bug:

- The nightly jobs try 5 times (`RecurringJob::CONFLICT_ATTEMPTS`),
  about 4 to 7.5 seconds of waiting in all. A job that runs out is
  marked failed, Bugsnag and healthchecks.io report it, and it runs
  again the next night. Every job is safe to run twice, so nothing is
  lost, only a day late. More tries would cost something: the worker
  runs one job at a time, so every job queued behind it, live pushes
  included, would wait while it sleeps between tries (about a minute at
  8 tries, about 4 minutes at 10).
- A push tries 3 times. The save it reports is already committed and
  the person who saved sees it. Other open screens miss that one update
  and show the old state until their next update or a reload. More
  tries would make the saving request wait longer, and the web dyno
  serves one request at a time.

Each limit needs many writes to the same rows in the same moment. The
storm makes hundreds a second; the community makes a few an hour.

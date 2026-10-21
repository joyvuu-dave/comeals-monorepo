# ADR 0005: SERIALIZABLE by default, with retry

- **Status:** Accepted (deployed to production 2026-08-02, confirmed 2026-08-03)
- **Date:** 2026-07-29
- **Amends:** decision 2 of ADR 0003
- **Issue:** [#43](https://github.com/joyvuu-dave/comeals-monorepo/issues/43)

## Context

ADR 0003 decided not to adopt `SERIALIZABLE`. The reason it gave is correct and
still holds: PostgreSQL's SSI only detects conflicts among transactions that
are all `SERIALIZABLE`, so making one transaction serializable buys nothing.
The only version that works is the whole application at `SERIALIZABLE`, with a
retry on every write path. ADR 0003 called that "a large change that buys what
two lines already buy" and said to revisit only if a test found a race the
locks do not cover.

No such test has been written and no such race has been found. So this ADR is
not a correction. It is a re-costing.

Two things prompted it. One is [an article on why teams avoid
`SERIALIZABLE`](https://blog.ydb.tech/do-we-fear-the-serializable-isolation-level-more-than-we-fear-subtle-bugs-5a025401b609),
whose argument is that the fear is mostly about throughput, and that an
application without a throughput problem is giving up a strong correctness
guarantee for nothing. The other is that this app is exactly that application:
one dyno, one community, about 30 residents, Puma at 1 thread and 0 workers.

The question this ADR answers is not "is `SERIALIZABLE` better." It is "what
would it actually cost here, and are the decisions along the way obvious."

## What we found

The survey on 2026-07-29 covered the settlement path, the meal-lock path, both
rake tasks, every model callback, and the cache configuration.

### Retry safety is already there, and it is not luck

A retried transaction is only safe if nothing irreversible happened before the
commit that failed. In this codebase nothing does:

- Every Pusher trigger in a model is `after_commit` — `unit.rb:39`,
  `resident.rb:114`, and the three reservation models. They fire only on
  success. `Meal#trigger_pusher` is not a callback at all: an `after_action`
  in `meals_controller.rb:22` calls it after the transaction is over (see
  decision 5). (Corrected 2026-08-23: an earlier version of this line said
  `meal.rb` had an `after_commit` hook. It never did.)
- Every cache invalidation is `after_commit` too. `community.rb:283` writes
  this down as a contract, not as a habit.
- Both `deliver_now` calls are outside any transaction:
  `residents_controller.rb:74` runs after the save returns, and the
  reconciliation mailers run after the settlement transaction returns
  (`Settlement.run!` since 2026-08-23; `Reconciliation.create!` before that).
  (Amended 2026-08-23: the password-reset `deliver_now` moved to
  `PasswordReset.request` in `app/services/password_reset.rb` on 2026-08-11,
  and the admin "Send password reset email" button calls it too. It still runs
  after `resident.save` returns, so the point holds.)

So a retried transaction in this app re-runs pure database work. This is the
single biggest reason the change is cheaper here than it would be elsewhere,
and it is a consequence of the `after_commit` discipline that already exists.

### There is one choke point, and it already opens a transaction

`with_meal_lock` (`meals_controller.rb:351`) is an explicit transaction that
every mutating meal action goes through — nine call sites. That is the whole
API write surface for the ledger. A retry placed inside it covers the API.

### Rendering happens inside that transaction

Eight of the nine actions call `render` inside the `with_meal_lock` block, and
`with_meal_lock` itself renders the rejection when the meal turns out to be
reconciled. Re-running the block after a rollback would raise
`DoubleRenderError`. This is the concrete code change the retry forces, and it
is the bulk of the diff.

### ActiveAdmin has no such choke point

Its thirteen resources open their transactions inside `resource` and
`build_resource`, where application code cannot reach them. Admin needs a
different retry boundary than the API does. **It turned out to need no retry at
all** — those same methods memoize the row they read, so any retry in the same
controller instance would reuse it. Decision 5 has the full reasoning.

### solid_cache shares the primary database

Every `Rails.cache.write`, every Rack::Attack counter increment, and the
background trim thread's deletes become serializable transactions against the
same database as the ledger. The counters are a read-modify-write on a hot key,
which makes them the likeliest source of aborts in the whole application — on
requests that have nothing to do with money.

**Measured 2026-07-29.** solid_cache's failsafe (`store/failsafe.rb`) swallows
a fixed list of transient errors, and `ActiveRecord::SerializationFailure` is
not on it — though its sibling `ActiveRecord::Deadlocked` is. So a `40001` on a
cache write would be raised into the request. The list is a plain constant and
is not frozen, so appending to it in an initializer is a one-line fix in the
spirit of the gem's own design. solid_cache assumed `READ COMMITTED`, where
serialization failures do not happen; it did not decide against handling them.

### The suite at SERIALIZABLE: 2 real failures, not 35

Measured 2026-07-29 by setting `default_transaction_isolation: serializable`
for the test environment only and running the suite. This replaces the guesses
in the rest of this ADR wherever the two disagree.

| Run                   | Result                     |
| --------------------- | -------------------------- |
| Full suite            | 1101 examples, 35 failures |
| Suite without spec/db | 1058 examples, 1 failure   |
| spec/db alone         | 43 examples, 1 failure     |

Thirty-three of the thirty-five were one failure amplified.
`spec/db/settlement_race_spec.rb` runs non-transactionally and cleans up with
`Meal.delete_all`. That cleanup **also** hit a serialization failure, so the
rows stayed. `spec/db` sorts first, so the following thousand examples ran
against a database that was supposed to be empty — and the rows persisted into
later runs, which makes this easy to misread as many independent problems.

The two real failures:

1. `spec/services/snapshot_read_spec.rb:60` asserts the isolation level inside
   the fixture transaction is `read committed`. Working as designed; update it
   when the flip ships. _Done: the spec (now line 27) asserts `serializable`._
2. `spec/db/settlement_race_spec.rb:306` (then line 308), "lets exactly one of
   two racing settlements survive". The losing settlement never reaches its
   compare-and-swap. SSI cancels it earlier, where `settlement_balances` reads
   the bills (`reconciliation.rb:139`): _"could not serialize access due to read/write
   dependencies... Canceled on identification as a pivot."_ The money outcome is
   unchanged — the loser rolls back whole — but the mechanism is different, so
   the assertion no longer describes what happens.

**What passed is the more important half.** The other nine examples in that
file — inserts, deletes and re-parenting across all three child tables — pass
unchanged, as do `settled_meal_triggers_spec.rb` and `whole_cents_check_spec.rb`.
The pessimistic locks and the immutability triggers from ADR 0003 behave
identically under SERIALIZABLE. That was the most likely thing to break.

_Correction, 2026-09-28: those nine examples send their racing write on a raw
libpq session, which never gets the `variables:` block, so that write ran at
READ COMMITTED, like psql. They show the locks and the trigger still stop a
write that skips the models. They do not show what a SERIALIZABLE model write
does in the same race. The file now has an example for that path ("a model
write from a second Rails connection"): the write's FOR KEY SHARE on the meal
waits for the settlement, and the write is then cancelled as a serialization
failure, before the trigger decides anything._

One limit on this evidence: 1058 of those examples run single-connection under
transactional fixtures, where an abort essentially cannot happen. They show
nothing broke structurally, and nothing more. Everything learned about real
abort behavior came from the one file with real threads, because it is the only
one that could show it.

## Decision

### 1. Set the isolation level per connection, not per transaction

`variables: { default_transaction_isolation: serializable }` in the `default:`
block of `config/database.yml`. This is applied at connect time, which is needed
for a reason found the hard way while shipping `SnapshotRead`: `SET
TRANSACTION` is refused once a transaction has run any query, so setting
isolation from application code hits a wall on every nested transaction,
including every spec running under transactional fixtures. Setting it at
connect time has no such problem.

Heroku Postgres does not allow `ALTER SYSTEM`, and generally not `ALTER
DATABASE` either, so "the whole instance" in the literal sense is not
available. `ALTER ROLE <user> SET default_transaction_isolation = 'serializable'`
covers `heroku pg:psql` and the Rails console as well. **Verified 2026-07-29:
the production role can set it.** Credential rotation is still the open risk —
a rotated role would not carry the setting — so `database.yml` remains the
mechanism to rely on and the role setting is a convenience for humans at a
prompt.

One trap, learned by walking into it. `heroku pg:psql` connects with the
`DATABASE_URL` credentials, which is the same role the app connects as, and
`ALTER ROLE ... SET` applies to every new session for that role. So running it
to "check whether it works" switches production, on the next dyno restart, with
no retry anywhere in the app. It was reverted with `RESET` the same day.
Anyone verifying this again should do it on a role the app does not use, or
accept that they are making the change rather than testing it.

### 2. Keep the pessimistic locks

`SERIALIZABLE` does not replace `with_meal_lock`, `assign_meals`' `FOR UPDATE`,
or the immutability triggers. Those turn a conflict into a wait, which produces
a readable 400. `SERIALIZABLE` turns a conflict into an abort, which produces a
retry. Waiting is better when we know where the conflict is. `SERIALIZABLE`
goes underneath the locks to catch write skew on a path nobody thought to lock.

Anyone proposing to remove a lock because "`SERIALIZABLE` covers it" is
proposing to make the system slower and less legible, not simpler.

### 3. Retry at the transaction boundary for the API

Put the retry inside `with_meal_lock`. Not in Rack middleware wrapping the
whole request: that would move every `after_commit` to the end of the request
and would re-send the password-reset email at `residents_controller.rb:74` on a
retry, because that email is sent after a save that would no longer have
committed. A request-wide transaction turns the one property that makes this
change cheap into the thing that breaks.

Retries: a small fixed count, three to five, with jitter. Out of retries
returns a 409 with a message the shared screen can show. That last part is a UX
decision, not only a technical one. The rule: the message says
what happened in plain words, and the safe action (tap again) stays under the
tap.

### 4. Rendering moves out of the lock

Each of the nine actions changes so the block returns what to render and the
action renders it afterwards. `with_meal_lock` returns the rejection rather
than rendering it, which also removes the `performed?` check at
`meals_controller.rb:262`. Mechanical, but it touches every mutating meal
action, and it must be done before any retry is switched on.

### 5. ActiveAdmin shows the message and does not retry

**Changed 2026-07-30. Shipped the same day.** This decision first said admin
would get an `around_action` on `ActiveAdmin::BaseController` that re-runs the
action and resets `response_body`. Reading the (then) twelve resources before writing
it showed that cannot work.

ActiveAdmin memoizes the row it read into `@meal`, `@bill` and so on, inside
`resource` and `build_resource`
(`ActiveAdmin::ResourceController::DataAccess`, `data_access.rb:89`). Those run
before any code we write. An `around_action` retries inside the same controller
instance, so the second attempt reuses the row the first attempt read. It would
write again from the read the database just refused, which is the opposite of
retrying — a retry has to re-read. Clearing those instance variables by hand
would work only while the gem keeps using the same names. An upgrade that
renamed them would make it stop working, with no error.

So `config/initializers/active_admin_conflict_rescue.rb` rescues
`ActiveRecord::TransactionRollbackError` on `ActiveAdmin::BaseController` and
redirects back with the same message the API sends: nothing was saved, try
again. The person retries by submitting the form again.

That is acceptable in admin and not in the API. Admin has one person using it
at a time, so the conflict is rare, and re-submitting is one click. It is also
what the shared screen already does — it reverts the change, shows the message,
and the person taps again.

Two of the three original reasons for the `around_action` were checked and hold,
and they are what makes the message truthful rather than what makes a retry
safe. No mail goes out before a commit: every `deliver_now` in the app is in a
rake task, except the password reset in `PasswordReset.request`. (Amended
2026-08-23: since 2026-08-11 admin calls `PasswordReset.request` from the
"Send password reset email" button in `app/admin/resident.rb`. It saves the
token before it mails, so a conflict raises before any email.) And no
Pusher event survives a rollback: Meal, Bill, MealResident and Guest send
theirs from an `after_action` in `Api::V1::MealsController`, so admin sends
none at all, while Event, Rotation, CommonHouseReservation and
GuestRoomReservation send theirs from `after_commit`, which does not run on a
rollback. The third reason — that a re-run form submit is harmless — was never
reached, because the re-run itself is what does not work.

The refusal is reported through `Rails.error` with `handled: true`. Nothing
retries here, so without that a conflict in admin would show up nowhere.

Devise's sign-in controllers inherit from Devise, not ActiveAdmin, so a
conflict while signing in is still a 500. That is a trackable write on a table
the money code never touches.

If a future ActiveAdmin stops memoizing the row, a retry becomes possible and
this is worth revisiting. `spec/requests/admin/conflict_rescue_spec.rb` checks
that it still memoizes, so that change is visible when it happens.

### 6. The batch reads are `READ ONLY DEFERRABLE`

**Shipped 2026-07-29**, ahead of the rest, because it stands on its own.
`SnapshotRead` (`app/services/snapshot_read.rb`) opens the transaction
`SERIALIZABLE READ ONLY DEFERRABLE`; `billing:recalculate` uses it.

`DEFERRABLE` is why this does not wait for the rest of the change.
A `SERIALIZABLE READ ONLY DEFERRABLE` transaction waits at the start until
PostgreSQL can give it a snapshot already free of serialization anomalies.
Having waited, it can never abort with a serialization failure and never causes
another transaction to abort. So it is strictly stronger than the
`REPEATABLE READ` it replaced while keeping the property that it needs no
retry. All three modes must be set together — `DEFERRABLE` has no effect
except on a `SERIALIZABLE READ ONLY` transaction.

One timing change to expect after the global switch: today nothing else runs at
`SERIALIZABLE`, so the snapshot is granted at once. (Amended 2026-08-23: "today"
here means before 2026-08-02. Since then every session runs at `SERIALIZABLE`,
so the wait described next is the current behavior.) Afterwards this block waits
for in-flight writers instead of racing them. For a nightly batch job that is
the behavior we want, but it is a change, and it is the kind that shows up as a
job that suddenly takes longer rather than as an error.

### 7. Decide the cache before switching, not after

A 40001 on a rate-limit counter must not become a 500 on a request that has
nothing to do with money. Measured: solid_cache does not swallow
`ActiveRecord::SerializationFailure` today, so this is real and not
hypothetical. The fix is to append that class to its
`TRANSIENT_ACTIVE_RECORD_ERRORS` constant in an initializer — a one-line change,
not the store wrapper this decision originally called for. "The volume is too
low for the counters to contend" is probably true and is not a reason to leave
it; a broken cache breaking a request is a stupid way to find out.

### 8. Write the retry tests before the retry

At 1 thread and 0 workers, with `FOR UPDATE` held on every ledger write path,
the production abort rate will be near zero. That is the good news and the bad
news: the retry path would be code that never runs until the day it is needed.
It needs deliberate fault injection, not "the suite still passes."

**The fault injection already exists.** `spec/db/settlement_race_spec.rb` runs
non-transactionally with real threads on real connections, and at SERIALIZABLE
it produces genuine `40001`s on demand, reliably. The stopping rule below was
written not knowing that. It is satisfied.

**If the fault injection turns out to be hard to build, stop and keep the locks
alone.** A retry we cannot test is worse than no retry.

### 9. Make the non-transactional spec cleanup retry-safe first

Found by measuring, and not anticipated anywhere above. A `delete_all` in a
spec's `after` block can abort with a serialization failure like any other
statement. When it does, the rows stay, every later example in the run sees
data that should not exist, and the mess survives into the next run. One
failing example became thirty-three.

This is the same problem as production, showing up first in test support code,
and it has to be fixed before anything else moves — otherwise every later
measurement is read through a poisoned database. It also means the retry helper
is needed by the specs before it is needed by the application.

### 10. One exception: Solid Queue's own bookkeeping runs at READ COMMITTED

Added 2026-10-20. Solid Queue keeps its records in the solid_queue\_\*
tables of this database: which processes are alive, which jobs are
ready, which a worker has claimed, which wait for a later time or for a
`limits_concurrency` slot. The transactions it opens on its own threads
to keep those records run at READ COMMITTED. Nothing else does: no app
table is ever written at READ COMMITTED, every job's `perform` runs at
SERIALIZABLE, and every job the app queues is written in the app's own
SERIALIZABLE transaction. So the settlement's two mail jobs still commit
or roll back with the settlement.

Why. At SERIALIZABLE these transactions cancel each other. Each process
writes its own row every 60 seconds, the processes start together, and
each write reads the whole small table, so two at the same moment cancel
one. On staging that was about 6 errors an hour; locally, 24 in 25
minutes, and 2 of 3 processes on every shutdown. The dispatcher moving a
due job to ready cancels against a worker's poll, and so does a job's
finish. Worse, a worker's poll reads the ready table, so it can make an
app transaction that queues a job fail when that transaction read a row
another request then changed; without the poll it would have committed.
Solid Queue does not retry its own steps. Each failure is a lost step
and an unhandled error in Bugsnag. And Solid Queue's next release stops
a process whose heartbeats keep failing past 5 minutes, and stops a
worker when it cannot mark a job finished
(rails/solid_queue#778 and commit e48f29b, both after 1.7.0), so these
failures would start stopping processes.

What it gives up. PostgreSQL checks for conflicts only among
SERIALIZABLE transactions, so these writes are outside that check. They
touch only Solid Queue's own tables, which no app transaction reads to
make a decision, and Solid Queue is written for READ COMMITTED (its
README says it runs that way itself). Some of its work stays at
SERIALIZABLE anyway. A step called inside a transaction that is already
open joins it at its level. And a few single reads that Solid Queue makes
outside any transaction, in loops whose other steps each have their own
transaction, still run at the session's level: the supervisor's reads of
dead processes and of the jobs they held, and the dispatcher's two reads
before it lets blocked jobs go. Wrapping those loops would join their
steps into one transaction (below). One conflict this does not remove:
an app transaction that queues a `limits_concurrency` job can still fail
if a job with the same key finished after it started, because it locks
that key's semaphore row. `RetryOnConflict` retries that, as it retries
any conflict.

How. `config/initializers/solid_queue_isolation.rb` lists the gem
methods that do this work. When one of them is called with no
transaction open, it runs inside one explicit
`SolidQueue::Record.transaction(isolation: :read_committed)`. The
transactions Solid Queue opens inside it join it, or become savepoints,
and neither asks for a level of its own. A statement Solid Queue used to
run outside any transaction (giving a semaphore back, deleting expired
semaphores, saving the scheduler's task list) now runs inside one.

Putting a method inside one transaction joins every transaction it used
to run into one. A failure late in the method then undoes work from
early in it, and locks are held longer. The initializer says, for each
method, how many it ran before and why one is safe. Where one is not
safe, a smaller piece is wrapped instead:

- When the worker finishes a job, Solid Queue marks it finished or
  failed, and only after that commits does it give the semaphore back
  and let the next blocked job go. It keeps them apart so that a failure
  in the second part cannot undo a job that already ran. So these are
  three wrapped steps, each its own transaction, not one.
- The scheduler's `RecurringTask#enqueue` rescues the error a second
  scheduler gets when the same run is already recorded. Inside an outer
  transaction that rescue would come before the rollback, and the
  duplicate job would be committed. So `RecurringExecution.record`, the
  part that queues and records, is wrapped instead.
- The dispatcher lets one blocked job go for each key in its own
  transaction. In one transaction it would hold every key's semaphore
  lock, in key order, while the app queues a settlement's two mail jobs
  in the other order: a deadlock. Each release is wrapped instead.

What came before, and why it changed. Until the evening of 2026-10-20
the wrapper used `ActiveRecord.with_transaction_isolation_level`, a
setting for the thread. Rails gives that level to every transaction it
opens, savepoints included, and refuses a level on a savepoint
(`TransactionIsolationError`). So every step that opens a savepoint
raised: the scheduler queued no recurring job on any tick (on staging
too, where every heartbeat was still fresh), a job that raised stayed
claimed, and a stopped worker could not remove itself. And the statement
that gives a semaphore back, outside any transaction, stayed at
SERIALIZABLE and was refused under load. `bin/storm` with
`STORM_SOLID_QUEUE=1` found all of it the same day. After a deploy,
`rake deploy:verify_recurring_job` now queues a recurring task the way
the scheduler does and fails unless the worker runs it.

The specs: `spec/db/solid_queue_process_rows_race_spec.rb` and
`spec/db/solid_queue_bookkeeping_race_spec.rb` (the conflicts),
`spec/config/initializers/solid_queue_isolation_spec.rb` (every method
wrapped; the methods that must stay apart are not on the list; a real
worker runs a job's `perform` at SERIALIZABLE and its own steps at READ
COMMITTED, finish, semaphore and release each in its own transaction; a
failed release leaves the finished job finished; an app enqueue, inside
a transaction or not, stays SERIALIZABLE; a second enqueue of the same
recurring run is rolled back),
`spec/config/initializers/solid_queue_isolation_savepoint_spec.rb` (the
steps that open a savepoint), and `spec/services/settle_and_notify_spec.rb`
(both mail jobs roll back with a refused settlement).

## Consequences

- `spec/db/settlement_race_spec.rb` needs one example rewritten, not the file.
  Measured: nine of its ten examples pass unchanged. The one that fails asserts
  the compare-and-swap fires, and under SERIALIZABLE the losing settlement is
  cancelled before it gets there. The money assertion still holds either way.
  (This bullet originally predicted "real work" for the whole file. That was
  too pessimistic, and the correction is left visible on purpose.)
- Every write path in the app gets a new failure mode that did not exist
  before. The locks mean it will almost never fire, which is precisely why it
  must be tested on purpose.
- `bin/check` runs the whole suite at `SERIALIZABLE` afterwards. The suite is
  single-connection under transactional fixtures, so most of it should not
  notice. The non-transactional groups are the ones to watch.
- The claim "read-only, so it cannot hit a serialization failure" stops being
  true by accident and starts being true by construction, but only for the
  transactions that go through `SnapshotRead`. Any new batch read that opens a
  plain transaction is exposed.

## Alternatives considered

- **Do nothing.** ADR 0003's position, and it is still defensible. The known
  hole is closed, and this change fixes no bug we can name. The case for acting
  anyway is that the hole in ADR 0003 was found by reading one code path, and
  reading code paths does not scale as a way to find the next one.
- **Wrap the whole request in one transaction.** Rejected in decision 3. It
  breaks the `after_commit` property that makes retry safe here.
- **Raise the isolation level only on the settlement.** Rejected, and this is
  ADR 0003's original point: SSI only detects conflicts among transactions that
  are all `SERIALIZABLE`. A serializable settlement against a `READ COMMITTED`
  admin request detects nothing.
- **Take the meal lock inside ActiveAdmin as well, and stop there.** This is
  the cheapest thing that closes the known class of problem. ADR 0003 rejected
  it as the primary fix because it is a per-call-site discipline the next new
  admin resource will forget. That objection is still right, and it is the same
  objection that argues for `SERIALIZABLE`: both are about the path nobody
  remembered to guard.

## Open questions

1. ~~Can the production role set `default_transaction_isolation`?~~ Answered
   2026-07-29: yes. Whether it survives credential rotation is still open, and
   is the reason decision 1 relies on `database.yml` rather than the role.
2. ~~Does solid_cache surface a serialization failure as a raised error or a
   cache miss?~~ Answered 2026-07-29: it raises. See decision 7.
3. ~~What does the shared screen show when a signup runs out of retries?~~
   Answered (marked 2026-08-23). The API returns 409 with "Someone else was
   changing this meal at the same time. Nothing was saved. Try again."
   (`conflict_rejection` in `meals_controller.rb`). The store reverts the
   toggle it just made (`app/frontend/src/stores/resident.js`) and
   `handleAxiosError` (`app/frontend/src/helpers/handle_axios_error.js`) shows
   the message as a toast. The safe action, tapping again, stays under the
   tap.

## What has shipped so far

- **2026-07-29** — decision 6, `SnapshotRead` and `billing:recalculate`.
- **2026-07-29** — error tracking (Bugsnag, both halves of the app). Not a
  decision in this ADR, but a prerequisite for all of it: this change adds a
  failure mode to every write path and a retry meant to hide it, and both were
  invisible before. `BugsnagErrorSubscriber` is what will carry the retry
  counts, via `Rails.error.report(handled: true)`.
- **2026-07-29** — decisions 8 and 9, and `RetryOnConflict`. The test
  environment runs at SERIALIZABLE; production does not yet. Suite green at
  1112 examples.
- **2026-07-29** — steps 1 and 2 of the rollout: no `render` inside
  `with_meal_lock`, and the retry-plus-409 around it. Step 3 the same day:
  solid_cache treats a serialization failure as transient.
- **2026-07-30** — step 4: ActiveAdmin rescues the conflict and redirects
  back with a message, instead of the planned `around_action` retry, which
  cannot work (decision 5 has the reasoning).
- **2026-08-02** — step 5 deployed (release v606). Every environment runs at
  SERIALIZABLE.
- **2026-08-03** — confirmed live: `SHOW default_transaction_isolation`
  through `heroku run rails runner` says `serializable`. Note that checking
  with `heroku pg:psql` says `read committed`, and that is expected: the
  setting comes from the `variables:` block in `database.yml`, so only Rails
  sessions get it. psql's own session never does.
- **2026-09-11** — the request storms (docs/concurrency-testing.md) found
  three paths that did not retry a refusal: a meal write on its second
  attempt (the record still held the values the first attempt tried, and
  `with_lock` refuses a dirty record), the calendar writes (no retry at
  all, a 500), and the recurring jobs (a failed run and a fail ping). All
  three now retry; the calendar writes answer 409 when the conflict does
  not go away, through `ApiController#render_retrying_on_conflict`.
- **2026-09-11** — the last path with no answer for a refusal: reads. The
  calendar month is rebuilt on a conflict, and `ApiController` rescues
  anything that still escapes — a refusal during a render, in a
  `before_action`, in any read action — as the same 409. A refused
  transaction has written nothing, so 409 is the true answer and 500
  never is. Decision 4 still holds: this is a rescue, not a retry,
  because by then the action may have rendered.
- **2026-09-11** — the retry budget belongs to the caller. `SettleAndNotify`
  gave every caller the nightly task's ten tries, which sleep two to four
  minutes before giving up, and that included the API's settle endpoint and
  the admin form. On a dyno that serves one request at a time, a contested
  settlement from a person stopped the app for everyone and still showed
  them an error, because Heroku's router gives up at 30 seconds.
  `SettleAndNotify::BATCH` and `::REQUEST` split it: three quick tries and
  a 409 when someone is waiting. The admin form also had no rescue for
  `Settlement::Contested` — not an ActiveRecord error, so neither
  RetryOnConflict nor the admin conflict rescue covered it — and answered
  500; it shows the try-again message now.
- **2026-09-11** — one lock order for a meal and its rows, everywhere.
  The API locked the meal and then the row; the settled-meal trigger
  locked them the other way round for any write that did not go through
  the API, so an admin edit against an API write on one meal deadlocked.
  `LocksItsMealFirst` takes the trigger's lock (`FOR KEY SHARE`) before
  the row instead of after it.
- **2026-10-09** — nothing after a write's commit may fail into "Nothing
  was saved". The 409 above is true only when nothing committed, so a
  write action now answers from what it read inside its own
  transaction. The settlement did not: after its commit it read its
  meals again for the cache clear, counted them for the answer, and
  queued the cook mail, and a refusal of any of the three answered 409
  for a settlement that was saved. Now the meals and the count are kept
  from inside the transaction, the cook mail job is a Solid Queue row
  written in the same transaction, and the steps after the commit report
  their errors instead of raising (`SettleAndNotify`). Two admin writes
  broke the same rule: a rotation delete renumbered and recolored the
  rotations left after its commit, so a refusal there showed "Nothing
  was saved" for a rotation that was gone (the two now run inside the
  delete's transaction, and a new rotation is numbered inside its own
  create's transaction too), and removing someone from a meal read
  their name for the notice after the commit (it is now read before).
  `spec/requests/no_query_after_commit_spec.rb` runs every API and
  admin route that writes, checks both lists against the routes, and
  fails on any query after the commit outside a step that reports its
  own errors. The same change made
  `RetryOnConflict` retry a conflict that Solid Queue wraps in its own
  `EnqueueError`; before that, a refused push enqueue was dropped after
  one try.
- **2026-10-16** — a lock is not a change. ADR 0003's trigger read the
  meal row `FOR KEY SHARE`, and at READ COMMITTED that was enough: the
  settlement waited for a racing write and then took a fresh snapshot.
  At SERIALIZABLE its snapshot was taken before the wait, a lock changes
  no row, and a write from psql runs at READ COMMITTED, outside the
  conflict check. So a settlement that waited for a psql write that
  started first settled without it, and a cancel that waited for a psql
  cost with money went through. The trigger now updates the meal row
  (`updated_at = updated_at`, migration `20261016120000`), so the
  waiting transaction fails as a conflict and is tried again with a
  fresh snapshot (`spec/db/settlement_after_a_raw_write_race_spec.rb`,
  `spec/db/cancel_against_a_cost_race_spec.rb`; ADR 0003, "The other
  order"). The 2026-09-11 entry above still holds for the order of the
  locks: `LocksItsMealFirst` locks the meal `FOR KEY SHARE` before the
  row, and the trigger's update comes after the row.
- **2026-10-20** — Solid Queue's own bookkeeping runs at READ COMMITTED,
  the one exception to this ADR (decision 10). Its heartbeats, its
  shutdown, its poll, its dispatch and its job finish cancelled each
  other at SERIALIZABLE, and the poll could cancel an app transaction
  that queued a job.

The full record of the rollout, step by step, is in
[docs/serializable-rollout.md](../serializable-rollout.md).

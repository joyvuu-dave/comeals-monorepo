# ADR 0005: SERIALIZABLE by default, with retry

- **Status:** Proposed
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

- Every Pusher trigger is `after_commit` — `unit.rb:38`, `resident.rb:85`,
  `meal.rb:154`, and the three reservation models. They fire only on success.
- Every cache invalidation is `after_commit` too. `community.rb:270` writes
  this down as a contract, not as a habit.
- Both `deliver_now` calls are outside any transaction:
  `residents_controller.rb:74` runs after the save returns, and the
  reconciliation mailers run after `Reconciliation.create!` returns.

So a retried transaction in this app re-runs pure database work. This is the
single biggest reason the change is cheaper here than it would be elsewhere,
and it is a consequence of the `after_commit` discipline that already exists.

### There is one choke point, and it already opens a transaction

`with_meal_lock` (`meals_controller.rb:339`) is an explicit transaction that
every mutating meal action goes through — nine call sites. That is the whole
API write surface for the ledger. A retry placed inside it covers the API.

### Rendering happens inside that transaction

Eight of the nine actions call `render` inside the `with_meal_lock` block, and
`with_meal_lock` itself renders the rejection when the meal turns out to be
reconciled. Re-running the block after a rollback would raise
`DoubleRenderError`. This is the concrete code change the retry forces, and it
is the bulk of the diff.

### ActiveAdmin has no such choke point

Its twelve resources open their transactions inside `resource` and
`build_resource`, where application code cannot reach them. Admin needs a
different retry boundary than the API does.

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
   when the flip ships.
2. `spec/db/settlement_race_spec.rb:308`, two settlements racing each other.
   The losing settlement never reaches its compare-and-swap. SSI cancels it
   earlier, where `settlement_balances` reads the bills
   (`reconciliation.rb:146`): _"could not serialize access due to read/write
   dependencies... Canceled on identification as a pivot."_ The money outcome is
   unchanged — the loser rolls back whole — but the mechanism is different, so
   the assertion no longer describes what happens.

**What passed is the more important half.** The other nine examples in that
file — inserts, deletes and re-parenting across all three child tables — pass
unchanged, as do `settled_meal_triggers_spec.rb` and `whole_cents_check_spec.rb`.
The pessimistic locks and the immutability triggers from ADR 0003 behave
identically under SERIALIZABLE. That was the most likely thing to break.

One limit on this evidence: 1058 of those examples run single-connection under
transactional fixtures, where an abort essentially cannot happen. They show
nothing broke structurally, and nothing more. Everything learned about real
abort behavior came from the one file with real threads, because it is the only
one that could show it.

## Decision

### 1. Set the isolation level per connection, not per transaction

`variables: { default_transaction_isolation: serializable }` in the `default:`
block of `config/database.yml`. This is applied at connect time, which matters
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
decision, not only a technical one — see `docs/` on the shared-screen
principles before choosing the wording.

### 4. Rendering moves out of the lock

Each of the nine actions changes so the block returns what to render and the
action renders it afterwards. `with_meal_lock` returns the rejection rather
than rendering it, which also removes the `performed?` check at
`meals_controller.rb:262`. Mechanical, but it touches every mutating meal
action, and it must be done before any retry is switched on.

### 5. ActiveAdmin gets an `around_action`

An `around_action` on `ActiveAdmin::BaseController` that re-runs the action and
resets `response_body`. This is the boundary rejected for the API in decision
3, and it is acceptable here for reasons that do not apply there: admin writes
are rare, admin actions do not send mail, and a re-run admin form submit is
harmless.

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
`SERIALIZABLE`, so the snapshot is granted at once. Afterwards this block waits
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
news: the retry path would be code that never runs until the day it matters.
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
3. What does the shared screen show when a signup runs out of retries? It
   should not be a raw error, and the safe action should stay under the tap.
   Still open, and it is a UX decision rather than a technical one.

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

The remaining steps, in the order to do them, are in
[docs/serializable-rollout.md](../serializable-rollout.md).

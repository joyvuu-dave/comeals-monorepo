# Concurrency testing

How this app is tested for what happens when many things run at once, and
what each test is for. The ideas come from
[Rails thread safety](https://pawelurbanek.com/rails-thread-safety): state
on a class or a thread is shared between requests; a read followed by a
write can lose an update; and the way to find both is to hit a real app
with many requests at the same time and check every answer.

Production runs Puma with one thread (`config/puma.rb`). These tests run
many on purpose: one thread hides every bug of this kind, and the other
processes production does have (a rake task in its own dyno, an admin in
a browser) are enough to trigger some of them (ADR 0003).

## The four layers

### 1. No process-wide mutable state — `spec/concurrency/process_wide_state_spec.rb`

Reads every file under `app/`, `lib/` and `config/initializers/` with Prism
and refuses class variables (`@@x`), `Thread.current`, and instance
variables written on a class (`@x ||=` inside `def self.` or `class <<
self`). One memo is allowed, `JwtAuth.secret`, because two threads that
race it derive the same bytes. `Current` (CurrentAttributes) is the one
allowed thread-local, because layer 2 proves Rails resets it.

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
a settler, the four nightly jobs, and an admin writing through the models
without the meal lock run beside them. `Rails.cache` and the Rack::Attack
counters are a real solid_cache in the test database, at SERIALIZABLE,
like production. What must hold:

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
  final rows, `ledger:verify` passes, a cap holds, the balance refresh is
  stable, and every calendar month reads the same with the cache and
  without it;
- writes went through and a settlement won while they did.

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
    STORM_POOL=2 bin/storm          # a pool smaller than the threads

Read `tmp/storm_server.log` after a run; the script prints its error
lines.

## What the storms found (2026-09-11)

All three were fixed the same day, each with a deterministic spec.

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

One thing the storm shows that is not a bug: routes are drawn lazily in
the test environment, on the first request, and many first requests at
once race that. Production eager loads, so the storm specs eager load
too.

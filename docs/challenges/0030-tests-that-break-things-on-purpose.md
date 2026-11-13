---
id: 30
title: Tests that break the network, the database and the clock
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-13
watches:
  - docs/concurrency-testing.md
  - docs/fault-testing.md
  - docs/adr/0015-idempotency-keys-on-calendar-writes.md
  - lib/database_unreachable.rb
  - app/controllers/concerns/keyed_writes.rb
---

# Tests that break the network, the database and the clock

## The challenge

The money rules hold when parts of the system fail in the middle of a write: a dropped connection, a restarted database, a clock that jumps.

## The case that breaks it

The browser sends a sign-up. The server commits it, but the network drops before the answer arrives. The browser tries again, and the person is signed up twice, or sees an error for a sign-up that worked.

## Where we stand

- `bin/faults` runs the real-server storm on a PostgreSQL of its own, through a proxy, while connections are cut, the database cannot be reached for a moment, PostgreSQL restarts and the server's clock jumps. It loses some answers to writes, and the phone sends them again. Afterwards it checks the books, that no write was saved twice, and that no saved write was answered with an error when sent again (`docs/fault-testing.md`). A 12-second run is in `bin/check` and CI (`spec/bin/faults_spec.rb`).
- A request that loses its database connection is answered 503 with a `Retry-After`, not 500 (`lib/database_unreachable.rb`).
- Every write the browser sends again is safe to send twice. A bills save and a guest add need an `Idempotency-Key` (ADR 0009). The calendar writes, a guest remove and a settle take one (ADR 0015, `spec/requests/api/v1/request_keys_spec.rb`). Attendance writes carry a version, and a second send is answered 409 "stale" (ADR 0012). On a settled meal, a close, a cancel, a description or a cap that sends the value the meal already has is answered as saved (#280, `app/controllers/concerns/settled_same_value.rb`).
- Not checked: a fault in Pusher or the mail server, a full disk, and a clock that moves on the database server itself (the app never reads it, `spec/db/app_clock_spec.rb`). No settle succeeded in the one-minute runs of 2026-11-12, so a settle sent again is checked by request specs only.

## Options

1. **A fault-injection suite** in the style of Jepsen: run `bin/storm`, and while it runs, drop connections (with a proxy such as toxiproxy), restart PostgreSQL, and move the clock. Afterwards, check every money rule and that every write that got a success answer is in the database once.
2. **Idempotency keys on every write** (also in challenges 2 and 3), so a retry is always safe.

## Decision

Both options, faults first (David, 2026-11-12). The fault suite is `bin/faults`, with its own PostgreSQL and a proxy written in Ruby instead of toxiproxy, so it never restarts the PostgreSQL the worktrees share. Its findings were fixed by `DatabaseUnreachable`, ADR 0015 and #280.

## History

- 2026-11-07: Opened.
- 2026-11-12: David chose both options, faults first, with a PostgreSQL of the suite's own and a proxy in Ruby.
- 2026-11-12: Done. `bin/faults` found 500s on a lost database connection (fixed: `DatabaseUnreachable`, 503) and writes that were not safe to send again (fixed: ADR 0015).
- 2026-11-13: `bin/faults` found a close sent again after a settlement answered 400 for a close that was saved (#280). David chose option 1: on a settled meal, a write that sends the value the meal already has is answered as saved. It also found that its own settler ran at READ COMMITTED; fixed in the suite.

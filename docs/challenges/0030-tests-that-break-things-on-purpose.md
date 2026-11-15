---
id: 30
title: Tests that break the network, the database and the clock
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-15
watches:
  - docs/concurrency-testing.md
  - docs/fault-testing.md
  - docs/adr/0015-idempotency-keys-on-calendar-writes.md
  - lib/database_unreachable.rb
  - lib/database_full.rb
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
- A request that PostgreSQL refuses because its disk is full is answered 507 with "nothing was saved", not 500 (`lib/database_full.rb`, `spec/requests/api/v1/database_full_spec.rb`). The fault suite does not fill a disk; the spec makes PostgreSQL raise its real `disk_full` error.
- Every write the browser sends again is safe to send twice. A bills save and a guest add need an `Idempotency-Key` (ADR 0009). The calendar writes, a guest remove and a settle take one (ADR 0015, `spec/requests/api/v1/request_keys_spec.rb`). Attendance writes carry a version, and a second send is answered 409 "stale" (ADR 0012). On a settled meal, a close, a cancel, a description or a cap that sends the value the meal already has is answered as saved (#280, `app/controllers/concerns/settled_same_value.rb`).
- Settles run all through a fault run. A settle phone settles one dinner at a time, and every one of its answers is lost once, so a settle that worked is sent again on every run and must get the same settlement back (`docs/fault-testing.md`, "The settle phone").
- Not checked: a fault in Pusher or the mail server, and a clock that moves on the database server itself (the app never reads it, `spec/db/app_clock_spec.rb`). Pusher and mail are kept out of the request: a push is a job that tries three times and reports (`LivePushJob`), and a reset or email change that cannot send its mail answers that it was not sent and keeps the token.

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
- 2026-11-13: David decided the Idempotency-Key stays optional for now. A page loaded before keys were added sends none, so requiring one would refuse those pages' writes. To look at again once every phone has loaded a newer page.
- 2026-11-14: David chose two of the gaps. First, a settle sent again under faults: the suite now plants a row of settleable dinners and a settle phone settles them one by one, with every answer lost once. Its first run found no bug in the app. The check first compared the two answers as text, and the stored answer comes back from `jsonb` with its keys in another order, so it compares parsed JSON. Second, a full disk: a write that hits PostgreSQL's `disk_full` error was answered 500, so the page said "The server had a problem" and treated the write as maybe saved. Nothing was saved: the error rolls the write back, and no write runs a query after its commit. David chose 507 Insufficient Storage with "nothing was saved" (2026-11-15), for API paths only; admin keeps the error page. Pusher, mail and the database server's clock are left as they are.

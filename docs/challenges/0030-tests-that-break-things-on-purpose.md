---
id: 30
title: Tests that break the network, the database and the clock
area: proof
status: open
opened: 2026-11-07
reviewed: 2026-11-12
watches:
  - docs/concurrency-testing.md
---

# Tests that break the network, the database and the clock

## The challenge

The money rules hold when parts of the system fail in the middle of a write: a dropped connection, a restarted database, a clock that jumps.

## The case that breaks it

The browser sends a sign-up. The server commits it, but the network drops before the answer arrives. The browser tries again, and the person is signed up twice, or sees an error for a sign-up that worked.

## Where we stand

- Concurrency is tested at five layers (`docs/concurrency-testing.md`). None of them cuts a connection, stops the database, or moves the real clock in the middle of a write. The seeded simulation (layer 5) picks the order of statements and fakes the app's clock, but it breaks nothing on purpose.
- Not checked: whether every write the browser retries is safe to send twice.

## Options

1. **A fault-injection suite** in the style of Jepsen: run `bin/storm`, and while it runs, drop connections (with a proxy such as toxiproxy), restart PostgreSQL, and move the clock. Afterwards, check every money rule and that every write that got a success answer is in the database once.
2. **Idempotency keys on every write** (also in challenges 2 and 3), so a retry is always safe.

## History

- 2026-11-07: Opened.

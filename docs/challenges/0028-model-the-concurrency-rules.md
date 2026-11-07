---
id: 28
title: Model the concurrency rules
area: proof
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - docs/adr/0003-concurrency-on-the-money-path.md
---

# Model the concurrency rules

## The challenge

Show, for every order in which writes can happen, that the concurrency rules keep the money rules true.

## The case that breaks it

The race specs try a few orders on purpose. ADR 0003 records that the settlement lock and the trigger were each tried alone and neither one worked; it took all three pieces. A fourth piece, or a change to one, could open an order no spec tries.

## Where we stand

- The protocol is described in `docs/adr/0003-concurrency-on-the-money-path.md` and pinned by the race specs in `spec/db/`.
- No TLA+ model exists.

## Options

1. **A TLA+ model of today's protocol:** a settlement, two sign-ups, an admin write and a psql write at READ COMMITTED, with the meal lock, the compare-and-swap and the trigger. TLC checks that a settled dinner never changes and that a settlement counts every row.
2. **Models of the designs in challenges 2 and 3,** assuming only the guarantees each design says it uses. If the property holds there, the locks are not needed under that design.

## History

- 2026-11-07: Opened.

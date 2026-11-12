---
id: 4
title: Many people changing many things at once
area: concurrency
status: open
opened: 2026-11-07
reviewed: 2026-11-13
watches:
  - docs/concurrency-testing.md
---

# Many people changing many things at once

## The challenge

The app keeps every guarantee, and stays quick, while many residents change many different things at the same time.

## The case that breaks it

At 6 PM, 30 people sign up for dinners, 5 cooks enter costs, someone books the guest room, and a settlement runs. If every write waits on one shared row, or one lock on a whole table, everyone waits in a line, and requests time out.

## Where we stand

- Puma runs 1 thread and 0 workers (AGENTS.md, Heroku section), so the web dyno handles one request at a time. That is for throughput, not safety.
- Writes to one dinner wait on that dinner's row (`with_meal_lock`), so different dinners do not wait on each other.
- Concurrency is tested at five layers, including an in-process storm in `bin/check` (`spec/concurrency/`), `bin/storm` against a real multi-threaded Puma, and a seeded simulation of the same storm whose failing seeds replay exactly (`spec/simulation/`; `docs/concurrency-testing.md`).
- Not checked: how many requests a second the app handles before people notice a wait.

## Options

1. **Measure first.** Run `bin/storm` with as many clients as the community has people, and write down the numbers in this file.
2. **More Puma threads or workers.** The locks, not the thread count, make the money path safe (ADR 0003), so this changes throughput only. Each thread needs a database connection.
3. **Keep every write small and touching only its own rows.** No row that every write touches, no table locks. The design in challenge 3 has this property: two different dinners never collide.
4. **For many writes to one dinner** (everyone at the Common House screen at once): each retry waits a short random time first, so the losers do not all collide again.

## History

- 2026-11-07: Opened, from a talk with the owner about heavy use.

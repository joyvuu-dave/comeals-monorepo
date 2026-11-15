---
id: 4
title: Many people changing many things at once
area: concurrency
status: done
opened: 2026-11-07
reviewed: 2026-11-15
watches:
  - docs/concurrency-testing.md
  - config/puma.rb
  - app/models/throttle_count.rb
---

# Many people changing many things at once

## The challenge

The app keeps every guarantee, and stays quick, while many residents change many different things at the same time.

## The case that breaks it

At 6 PM, 30 people sign up for dinners, 5 cooks enter costs, someone books the guest room, and a settlement runs. If every write waits on one shared row, or one lock on a whole table, everyone waits in a line, and requests time out.

## Where we stand

Measured on 2026-11-15.

- Real use is small. In the copy of production from October 2026: 39 active residents; the busiest minute ever had 23 new sign-ups, guests and costs, and the busiest 10 seconds had 6. Only 42 minutes in the whole history had 10 or more. Deletes and page reads leave no row, so they are not counted.
- Puma runs 1 thread and 0 workers (`config/puma.rb`), so the web dyno answers one request at a time. That is for throughput, not safety.
- One thread on the laptop (`STORM_THREADS=1 STORM_WORKERS=0 bin/storm`, 30 seconds, clients that never pause): 1 client got 161 requests a second (p50 4.6 ms, p95 18 ms); 39 clients got 108 (p50 344 ms, p95 531 ms); 160 clients got 115 (p50 1.4 s, p95 1.7 s). No 500 at any size. Past one client the wait is the line in front of the one thread.
- The Basic dyno is about 4 to 13 times slower than the laptop. From the router logs, 20 minutes on 2026-11-15: the calendar took 75 ms (p50, laptop 19 ms), and 63 saves of a menu took 51 ms (p50, laptop 3.9 ms; slowest 260 ms). So one thread in production answers about 10 to 35 requests a second, and the busiest minute ever needed under 1.
- Writes to one dinner wait on that dinner's row (`with_meal_lock`), so different dinners do not wait on each other.
- A write that conflicts is tried again after a short random wait: 10 to 20 ms, then 20 to 40 ms, 3 tries in all (`app/services/retry_on_conflict.rb`). That is option 4 below.
- Requests from one address at the same moment, the Common House iPad or homes that share an internet connection, each add to one Rack::Attack count. Until 2026-11-15 that count could go back to 1, and 40 login tries at once were all let through (#292). The counts are now rows in `throttle_counts`, written at READ COMMITTED, so none is lost or refused (`spec/concurrency/shared_address_spec.rb`, ADR 0005 decision 11).
- More threads work. `bin/storm` at 16 threads and 2 workers, 64 clients for 20 seconds, four of them on one address: 224 requests a second (p50 226 ms, p95 680 ms), no problems, and the server counted 227 requests from the shared address, exactly what its clients sent.
- Concurrency is tested at five layers, including an in-process storm in `bin/check` (`spec/concurrency/`), `bin/storm` against a real multi-threaded Puma, and a seeded simulation of the same storm whose failing seeds replay exactly (`spec/simulation/`; `docs/concurrency-testing.md`). In all three, four clients share one address.

## Options

1. **Measure first.** Run `bin/storm` with as many clients as the community has people, and write down the numbers in this file.
2. **More Puma threads or workers.** The locks, not the thread count, make the money path safe (ADR 0003), so this changes throughput only. Each thread needs a database connection.
3. **Keep every write small and touching only its own rows.** No row that every write touches, no table locks. The design in challenge 3 has this property: two different dinners never collide.
4. **For many writes to one dinner** (everyone at the Common House screen at once): each retry waits a short random time first, so the losers do not all collide again.

## Decision

Option 1, done 2026-11-15; the numbers are above. One thread answers 10 to 35 times what the busiest minute ever needed, so options 2 and 3 are not done now. The one thing that broke when requests ran at the same moment, the Rack::Attack count, is fixed (#292, ADR 0005 decision 11), so threads can be added when they are needed, by setting `RAILS_MAX_THREADS` (and a pool to match). Option 4 was already built (`app/services/retry_on_conflict.rb`).

## History

- 2026-11-07: Opened, from a talk with the owner about heavy use.
- 2026-11-15: Measured (option 1). The storms gave every client its own address, so none sent two requests from one address at once; a spec that did found the Rack::Attack count going back to 1 (#292).
- 2026-11-15: The owner decided: fix the count with a table of its own at READ COMMITTED; have four storm clients share one address from now on; do not add threads now, because one thread is far from full; and record that the app is ready for more threads once the fix is merged.

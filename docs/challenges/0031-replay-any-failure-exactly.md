---
id: 31
title: Replay any failure exactly
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-13
watches:
  - spec/support/simulation/scheduler.rb
  - spec/support/simulation/determinism.rb
  - spec/support/simulation/world.rb
  - spec/support/simulation_seeds.rb
---

# Replay any failure exactly

## The challenge

Any failure a test finds can be run again, step for step, as often as needed.

## The case that breaks it

A storm test fails once in 200 runs. The run used real threads, the real clock and real randomness, so it cannot be repeated. The failure is closed as "flaky", and the real race is still there.

## Where we stand

- The money property specs use a seed, and a failure prints the command that runs that seed alone (`spec/support/property_seeds.rb`).
- The request storm also runs under a seeded scheduler: one SQL statement runs at a time, and the seed picks whose (`spec/support/simulation/scheduler.rb`). The clock, `sleep`, `rand` and `SecureRandom` come from the seed while it runs (`spec/support/simulation/determinism.rb`), and every run starts from empty tables with ids from 1 (`spec/support/simulation/world.rb`). Two runs of one seed give the same statements in the same order and the same answers (`spec/simulation/storm_spec.rb`).
- `bin/check` runs two seeds. `SIM_SEEDS=<n>` runs many, `SIM_SEED=<n>` replays one, and `SIM_CLIENTS` / `SIM_SECONDS` set the storm's size (`spec/support/simulation_seeds.rb`). A failed seed prints the command that reruns it and writes every statement of the run to `tmp/simulation/` (`spec/simulation_seeds_spec.rb`). A seed that passes drops its trace, so a search of thousands of seeds does not keep them all in memory. `SIM_FIRST_SEED` moves the first seed, and the Seed search workflow (`.github/workflows/seed-search.yml`) uses it to run a thousand new seeds every Sunday.
- A race planted on purpose in the meal cap is found by some seed and found again by the same seed every time (`spec/simulation/scheduler_planted_race_spec.rb`).
- The real-thread storms (`spec/concurrency/request_storm_spec.rb`, `bin/storm`) still use real time; a failure there still cannot be replayed. What the seed does not control yet is listed in #270.

## Options

1. **Deterministic simulation** (how FoundationDB is tested): run the app's write paths in one thread, with a fake clock and a scheduler that picks which step runs next from a seed. Any failing seed replays exactly.
2. Record the order of database statements in a storm run, so a failure can at least be read step by step.

## Decision

Option 1, with the readable record of option 2: the seeded scheduler and its trace (`docs/concurrency-testing.md`, layer 5). Built on branch `agent/replay-any-failure`. What the seed does not control yet is #270.

## History

- 2026-11-07: Opened.
- 2026-11-12: David chose option 1 with a readable record: a scheduler that lets one SQL statement run at a time and uses a seed to pick whose turn it is, with a fake clock, plus a printout of the steps of a failed run. It is to drive the whole storm API (every action `Storm::Client` sends), and `bin/check` runs a few seeds; one setting runs many, another replays one. Work started on branch `agent/replay-any-failure`.
- 2026-11-12: Built and closed. David chose to close the challenge once the work merges, and to list what the seed does not control in a new issue (#270) rather than keep this challenge open for it.
- 2026-11-12: David approved a weekly workflow that runs new seeds (after an overnight search of 2700 seeds found no race).

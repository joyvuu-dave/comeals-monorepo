---
id: 31
title: Replay any failure exactly
area: proof
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Replay any failure exactly

## The challenge

Any failure a test finds can be run again, step for step, as often as needed.

## The case that breaks it

A storm test fails once in 200 runs. The run used real threads, the real clock and real randomness, so it cannot be repeated. The failure is closed as "flaky", and the real race is still there.

## Where we stand

- The money property specs use a seed, and a failure prints the command that runs that seed alone (`spec/support/property_seeds.rb`).
- The concurrency storms use real threads and real time, so a failure there cannot be replayed exactly.

## Options

1. **Deterministic simulation** (how FoundationDB is tested): run the app's write paths in one thread, with a fake clock and a scheduler that picks which step runs next from a seed. Any failing seed replays exactly.
2. Record the order of database statements in a storm run, so a failure can at least be read step by step.

## History

- 2026-11-07: Opened.

---
id: 11
title: The same answer after every deploy
area: money
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# The same answer after every deploy

## The challenge

A deploy never changes what any dinner costs, unless the deploy is meant to.

## The case that breaks it

1. A deploy changes a sort, a rounding call, or how a guest is counted.
2. Every unsettled dinner now computes a slightly different charge.
3. Nothing fails: the specs build their own data, and the new numbers still add up to zero. The community is charged differently from what the screens showed the day before.

## Where we stand

- Settled dinners keep their stored lines, and triggers refuse changes to them, so a deploy cannot change them.
- `spec/support/oracle/plain_ledger.rb` is a second ledger written only from the docs, and specs compare the real ledger with it on random dinners (`spec/services/meal_ledger_against_plain_ledger_spec.rb`, `spec/tasks/stored_ledger_against_plain_ledger_spec.rb`).
- A replay of a production backup through the old and new code was done by hand in September 2026, and the tables were identical. It is not part of every deploy.
- The daily ledger check compares settled balances with their source data, not one release's numbers with another's.

## Options

1. **A replay on every deploy:** restore the latest production backup, compute every unsettled dinner with the live code and with the new code, and refuse the deploy if any line differs, unless the release note says it should. The staging rehearsal already restores a production backup (`bin/staging-rehearsal`), so this can run there.
2. Store each unsettled dinner's computed lines and compare them in the nightly check.

## History

- 2026-11-07: Opened.

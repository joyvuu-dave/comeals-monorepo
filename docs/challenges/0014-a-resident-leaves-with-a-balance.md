---
id: 14
title: A resident leaves or dies with a balance
area: people
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# A resident leaves or dies with a balance

## The challenge

When a resident moves out or dies, what they owe or are owed is closed out by a written rule, and the ledger still adds up.

## The case that breaks it

A resident cooked for three dinners and is owed $84, then moves away. An admin retires them (`active` set to false). The next settlement still lists them as owed $84. Nobody is sure who pays it, to whom, or whether the amount can be dropped.

## Where we stand

- A resident with ledger rows cannot be deleted; they are retired with the `active` flag (AGENTS.md, deletion policy).
- A settlement line can be marked Paid, or Let go by a superuser (ADR 0011).
- Not checked: whether a retired resident's settlement line shows anything different from an active one's.

## Options

1. Write the rule in the settlement ADR: what happens to a retired resident's line, who may let it go, and what the screen shows.
2. A "final settlement" for one resident, for when they leave between periods.

## History

- 2026-11-07: Opened.

---
id: 16
title: A former resident asks to be deleted
area: people
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# A former resident asks to be deleted

## The challenge

A former resident can ask for their personal data to be removed, and the ledger still adds up afterwards.

## The case that breaks it

A privacy law gives people the right to have their data erased. A former resident asks. But their name is on settled dinners, history rows and settlement lines, and the money rules say settled records never change. Deleting the rows breaks the ledger. Keeping them keeps the person's name.

## Where we stand

- Residents with ledger rows cannot be deleted, by design (AGENTS.md, deletion policy).
- The `audits` table keeps old values, going back to 2017.
- Not checked: which law, if any, applies to this community.

## Options

1. **Remove the person, keep the money.** Replace their name, email, phone and birthday with a fixed label ("Former resident 41"), and remove their old values from `audits`. Every money row stays, linked by id.
2. **Separate the person from the ledger.** Keep personal data in its own table, linked by an id the ledger uses. Deleting that one row removes the person.

## History

- 2026-11-07: Opened.

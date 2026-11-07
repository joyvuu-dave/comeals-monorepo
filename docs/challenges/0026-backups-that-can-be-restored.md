---
id: 26
title: Backups that can be restored and read
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - bin/staging-rehearsal
---

# Backups that can be restored and read

## The challenge

A backup can be restored when needed, and the data can still be read in 50 years, without the tools we use today.

## The case that breaks it

1. The database is lost, and the newest backup turns out to be broken. Nobody had restored one in months.
2. Or: in 2070, someone has a backup file but no PostgreSQL that reads its format.

## Where we stand

- Heroku keeps backups, and `bin/deploy` takes one before each deploy.
- `bin/staging-rehearsal` restores a fresh production backup into staging and deploys to it, so a restore is tried whenever the rehearsal runs. It runs only when someone starts it.
- `docs/runbooks/undo-a-deploy.md` has the restore steps.
- Not done: an export in a plain format (CSV with the schema written next to it), and a scheduled restore that runs with nobody starting it.

## Options

1. A monthly job that restores the newest backup into staging, runs `rake ledger:verify` on it, and alerts when either fails.
2. A yearly plain export, stored outside Heroku: one CSV per table and a text file describing every column.

## History

- 2026-11-07: Opened.

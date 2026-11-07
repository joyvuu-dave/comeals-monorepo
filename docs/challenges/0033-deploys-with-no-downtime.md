---
id: 33
title: Deploys with no downtime
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Deploys with no downtime

## The challenge

A deploy never shows the maintenance page, even one that changes the database.

## The case that breaks it

A deploy with a migration runs at 6 PM. For a few minutes everyone at the Common House screen sees the maintenance page, during sign-ups.

## Where we stand

- A deploy with migrations is a maintenance deploy: `bin/deploy` turns maintenance on and stops web and the worker while the migrations run (AGENTS.md, Heroku section). v625 on 2026-11-07 was one.
- The Deploy workflow promotes with no maintenance, which is safe only for a migration the old code can run beside (`.github/workflows/deploy.yml`).

## Options

1. **Split every schema change into steps the old and new code both work with:** add the new column, deploy code that writes both, copy the data, deploy code that reads the new one, then remove the old one. Each step deploys with no maintenance.
2. A check that refuses a migration the old code cannot run beside (strong_migrations catches some, not all: #133).
3. Deploy only at hours with no dinners, and write the hours down.

## History

- 2026-11-07: Opened.

---
id: 23
title: Someone else has to take over
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Someone else has to take over

## The challenge

If the one developer stops working on the app, someone in the community can keep it running, deploy a fix, and settle a period, using only what is written down.

## The case that breaks it

The developer is unreachable for three months. The Gmail app password stops working, so no password reset email arrives. Nobody else can sign in to Heroku, knows where the config is, or knows that `bin/deploy` exists. Dinners go on, on paper.

## Where we stand

- The runbooks cover deploys, undoing a deploy, and repairs to settled data (`docs/runbooks/`).
- AGENTS.md describes the system for a coding agent.
- Not written: a guide for a person who has never seen the code, a list of every account the app needs and who can sign in to each, and where the secrets are kept.
- Not tried: someone other than the developer following the docs.

My view (not a checked fact): this is the most likely way for the app to stop working.

## Options

1. **A "start here" guide for a successor:** the accounts, how to get access, the five tasks they will need (deploy, undo, settle, reset an admin, renew the domain), and who to ask.
2. **A second person with access to each account,** written in that guide.
3. **A practice run:** someone else follows the guide on staging, and every place they get stuck becomes a fix to the guide.

## History

- 2026-11-07: Opened.

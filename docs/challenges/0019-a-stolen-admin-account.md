---
id: 19
title: A stolen superuser account
area: security
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - docs/adr/0004-admin-authorization.md
---

# A stolen superuser account

## The challenge

One stolen admin account cannot move money.

## The case that breaks it

An attacker gets one superuser's password. They change bills on unsettled dinners, mark settlement lines as Let go, and run a settlement. Each step is allowed, because a superuser may do all of it.

## Where we stand

- Three admin levels; the money path needs a superuser (`docs/adr/0004-admin-authorization.md`).
- Every admin change is in the audit history.
- No action needs a second person.
- Not checked: whether admin sign-in has a second factor.

## Options

1. **A second factor for superusers** (an authenticator app).
2. **Two-person approval for money actions:** a settlement, a correction, or Let go is proposed by one superuser and done only after a second one approves.
3. **An email to every superuser** when a money action is done, so a stolen account is noticed the same day.

## History

- 2026-11-07: Opened.

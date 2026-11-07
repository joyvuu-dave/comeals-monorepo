---
id: 15
title: A family shares one email address
area: people
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# A family shares one email address

## The challenge

Two adults who share one email address can each have an account.

## The case that breaks it

Two partners use one family address. The admin gives it to the first. The second cannot have it, because emails are unique (`index_residents_on_lower_email` in `db/structure.sql`). So the second partner has no email, cannot reset a password, and gets no notices.

## Where we stand

- One email per resident, enforced by the unique index above.
- Since v625, an adult can edit a child in the same unit who has no email (ADR 0014), but not another adult.

## Options

1. Keep one email per person, and write down that each adult needs their own address.
2. Sign-in by email plus a choice of person when two share it. Password reset and the new email-change link then need to name the person too.

## History

- 2026-11-07: Opened.

---
id: 18
title: Password hashing gets weaker over time
area: security
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Password hashing gets weaker over time

## The challenge

Stored passwords stay hard to crack as computers get faster, with no one asked to change their password.

## The case that breaks it

Hashes made with today's cost setting are stolen in 2040. Computers then are much faster, so the cost that was strong in 2026 is now weak, and many passwords are cracked.

## Where we stand

- Passwords are hashed with scrypt (`Resident#password=` in `app/models/resident.rb`, and the same in `app/models/common_house_login.rb`).
- Not found: a step that hashes a password again with a higher cost when its owner signs in.

## Options

1. **Hash again on sign-in.** After a correct password, if the stored hash used a lower cost than today's, store a new hash. Over time every active account moves to the new cost.
2. **Raise the cost on a schedule,** written in this doc with the date.
3. Move to a newer algorithm (Argon2id) the same way, one sign-in at a time.

## History

- 2026-11-07: Opened.

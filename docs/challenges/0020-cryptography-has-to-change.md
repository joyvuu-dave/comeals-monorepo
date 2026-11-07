---
id: 20
title: The cryptography has to change
area: security
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - app/services/jwt_auth.rb
---

# The cryptography has to change

## The challenge

We can change the token signing key or the signing method at any time, with nobody signed out and no deploy that has to be timed to the minute.

## The case that breaks it

The signing key leaks (a log, a laptop backup). Every token anyone ever made can now be forged. Changing the key signs out every resident and the Common House screen at once, during dinner.

## Where we stand

- Tokens are signed with HS256 and one key (`ALGORITHM` in `app/services/jwt_auth.rb`).
- A token carries the `keys_valid_since` it was made with, and is good only while that value is unchanged, so one person's tokens can be ended (#265).
- Not found: a way to accept two keys at once while moving from one to the other.

## Options

1. **Key ids in the token** (`kid`), and a list of keys the server accepts. Add the new key, sign with it, and remove the old one once its tokens have expired.
2. Write the steps as a runbook, and practise them on staging.

## History

- 2026-11-07: Opened.

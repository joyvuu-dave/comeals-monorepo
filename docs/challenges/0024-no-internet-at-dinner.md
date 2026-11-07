---
id: 24
title: No internet at dinner time
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# No internet at dinner time

## The challenge

People can sign up and check in at the Common House when the internet is down, and nothing is lost or counted twice when it comes back.

## The case that breaks it

The Common House wifi is down from 5 PM to 8 PM on a dinner night. People write their names on paper. The next day someone types them in, misses two, and adds one person twice.

## Where we stand

- The app needs the server for every change. With no network, the screen shows that it is offline.
- Not checked: what happens to a change made just as the network drops (whether the screen says it failed, or seems to succeed).

## Options

1. **A clear offline message and a printed sign-up sheet** with a fixed format, so typing it in later is easy to check.
2. **Offline changes on the device, sent when the network comes back.** This brings back every concurrency question from challenges 2 and 3, now between devices that cannot talk to each other. Each change needs an idempotency key, and the server decides each one in order (for example, the seat limit) when it arrives.

## History

- 2026-11-07: Opened.

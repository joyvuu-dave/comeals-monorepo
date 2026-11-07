---
id: 10
title: A currency other than the US dollar
area: money
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - docs/foreign-communities.md
---

# A currency other than the US dollar

## The challenge

The app works for a community that pays in another currency, or after the dollar itself changes (a new unit, or a smallest coin other than one cent).

## The case that breaks it

A community in Japan uses the app. The yen has no cents, so "round to cents at settlement" rounds to a unit that does not exist, every screen shows "$", and the cost input refuses "1500" without cents or reads it wrong.

## Where we stand

- `docs/foreign-communities.md` has the notes: the hard part is currency, not phone numbers. "$" is in the display helper, the cap, and the cost input.
- The money rules (AGENTS.md) say "dollars" and "cents" throughout.
- The app serves one community forever (AGENTS.md), so this means changing that community's currency, not running two at once.

## Options

1. A `currency` column on the community (ISO 4217 code), the number of minor-unit digits read from it, and every display and input going through it.
2. Keep dollars, and write down that the app is for US communities.

## History

- 2026-11-07: Opened. The earlier notes are in `docs/foreign-communities.md` (2026-08-16).

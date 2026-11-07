---
id: 13
title: Names that look the same but are different text
area: people
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Names that look the same but are different text

## The challenge

Two names that look exactly the same on screen count as the same name.

## The case that breaks it

"José" can be typed two ways: with é as one Unicode character, or as e followed by a combining accent mark. They look the same, but the bytes differ, so `lower(name)` differs and the unique index allows both. The calendar then shows two residents named José, and a search for one finds only one of them.

## Where we stand

- Not handled: no code calls `unicode_normalize` on names or emails (searched `app/` and `lib/` on 2026-11-07).

## Options

1. Normalize names and emails to Unicode NFC before saving, in one model callback, with a data migration for existing rows.
2. Also refuse names with characters that only look like letters from another alphabet (a Cyrillic "а" in a Latin name). That is harder, and names in other alphabets are real.

## History

- 2026-11-07: Opened.

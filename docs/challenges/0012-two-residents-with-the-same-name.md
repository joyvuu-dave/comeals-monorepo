---
id: 12
title: Two residents with the same name
area: people
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Two residents with the same name

## The challenge

Two people with the same name can both live in the community and use the app.

## The case that breaks it

A second "John Smith" moves in. The admin adds him, and the database refuses the row, because a unique index allows only one resident per name, ignoring case.

## Where we stand

- `index_residents_on_lower_name` is a unique index on `lower(name)` (`db/structure.sql`).
- The index exists for good reasons. Screens and the history show a resident by name, and two rows with one name would make "who signed up?" unclear. `ResidentNameShortener` (`app/services/resident_name_shortener.rb`) also depends on it: its last step, the full name, is only safe because names are unique.
- Since v625, a resident can change their own name (ADR 0014), and the same index refuses a name already taken.

## Options

1. Keep the rule, and tell the admin to add something that makes the name different ("John Smith (B unit)"). This is the rule now, unwritten.
2. Drop the unique index, and show a second thing next to a name wherever two people share it (unit, or a middle initial). Every screen that lists people needs that change.

## History

- 2026-11-07: Opened.

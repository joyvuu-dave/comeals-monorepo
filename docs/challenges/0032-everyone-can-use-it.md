---
id: 32
title: Everyone can use it
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Everyone can use it

## The challenge

Every screen meets WCAG 2.2 AA: it works with a screen reader, with a keyboard only, with large text, and for people who see colors differently.

## The case that breaks it

An older resident with low vision uses the Common House screen with the text made larger. The sign-up buttons overlap, and they tap the wrong person's name.

## Where we stand

- Lighthouse gave the sign-in page 100 for accessibility on 2026-11-07 (phone and desktop). It could not test the signed-in pages (challenge 35).
- Color contrast for calendar chips is pinned by a spec (`spec/serializers/calendar_chip_contrast_spec.rb`).
- Not checked: a screen reader, keyboard-only use, or 200% text on the calendar and meal pages.

## Options

1. An automated accessibility check (axe) on every page in the browser suite, failing on any violation.
2. A by-hand pass with VoiceOver and the keyboard on the calendar and meal pages, with what was found written here.

## History

- 2026-11-07: Opened.

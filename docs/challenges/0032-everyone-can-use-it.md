---
id: 32
title: Everyone can use it
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-16
watches:
  - tests/helpers/accessibility.js
  - tests/e2e/keyboard.spec.js
---

# Everyone can use it

## The challenge

Every screen meets WCAG 2.2 AA: it works with a screen reader, with a keyboard only, with large text, and for people who see colors differently.

## The case that breaks it

An older resident with low vision uses the Common House screen with the text made larger. The sign-up buttons overlap, and they tap the wrong person's name.

## Where we stand

- axe checks every screen the visual suite pictures (65 screens, in Chromium and WebKit) against WCAG 2.2 A and AA and axe's best-practice rules, and fails on any finding (`expectAccessible` in `tests/helpers/accessibility.js`, called before each screenshot in `tests/e2e/visual.spec.js`). A test in `tests/e2e/keyboard.spec.js` fails when a screenshot has no axe check before it.
- Keyboard: `tests/e2e/keyboard.spec.js` signs a resident up, adds a guest, opens a dinner from the calendar and closes a form with the keyboard alone. On 12 screens it presses Tab until the focus comes back to the start, and fails when a stop shows no focus ring or when something with a pointer cursor was never reached. In WebKit it presses Option+Tab, because Safari's Tab stops only on text fields unless that setting is changed.
- The focus ring is one 3px near-black outline, shown by `:focus-visible` (the end of `app/frontend/src/components.css`). A tap on a button shows no ring. A text field shows it whenever it has the focus, tapped or not.
- Lighthouse gave the sign-in page 100 for accessibility on 2026-11-07 (phone and desktop). It could not test the signed-in pages (challenge 35).
- Color contrast for calendar chips is pinned by a spec (`spec/serializers/calendar_chip_contrast_spec.rb`).
- Not checked: a screen reader, or 200% text on the calendar and meal pages. axe cannot tell whether what a screen reader says makes sense, or whether larger text makes controls overlap.

## Options

1. An automated accessibility check (axe) on every page in the browser suite, failing on any violation.
2. A by-hand pass with VoiceOver and the keyboard on the calendar and meal pages, with what was found written here.

## History

- 2026-11-07: Opened.
- 2026-11-16: An axe scan of 10 screens found no color contrast failures, so the colors stay. A Tab walk found that a keyboard cannot sign someone up, add a guest, or open anything on the calendar, and that the focus ring is faint or missing. The owner chose: fix those, use one strong focus ring for the keyboard, make axe (option 1) and a Tab walk part of the browser suite. A VoiceOver pass (option 2) is left for the owner.
- 2026-11-16: Built option 1 and the keyboard checks. The sign-up name, the guest menu and the calendar entries became buttons and links, and every page got an h1. axe on all 65 screens also found the menu's "Not saved" text too faint on yellow (now brand red), a link on the crash page shown by color alone (now underlined), day buttons whose names did not hold the number shown, and a rotation bar too small to tap (now 24px tall). Still to do: a VoiceOver pass and 200% text.

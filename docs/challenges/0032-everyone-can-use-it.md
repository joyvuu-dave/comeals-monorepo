---
id: 32
title: Everyone can use it
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-18
watches:
  - tests/helpers/accessibility.js
  - tests/e2e/keyboard.spec.js
  - tests/e2e/text-size.spec.js
  - tests/ios/check.mjs
  - tests/ios/known_failures.txt
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
- Large text, by zoom: zooming a page to 200% halves its width in CSS pixels. `tests/e2e/text-size.spec.js` lays out ten screens (login, calendar, meal, closed meal, the four new forms, event edit, rotation) at half the width of an iPad on its side (590), an upright iPad (410) and a laptop (640), and at 320 by 180 (a laptop at 400%, WCAG 1.4.10). It fails when the page is wider than the screen, when two controls are drawn on top of each other, when a box cuts off text or text spills out of a button, link, heading or header bar (`findLayoutProblems` in `tests/helpers/accessibility.js`), or when a form's main button is not on screen without scrolling. The month grid is never narrower than 400 pixels; on a narrower screen it scrolls sideways in its own box and the rest of the page fits the width.
- Large text, in iOS Safari: `bin/test-ios` drives real Safari in the iPhone 17 and iPad mini simulators (Xcode, through Apple's safaridriver) against the seeded Rails test server. It opens nine screens at normal text and at 200% text, set with `-webkit-text-size-adjust`, which in iOS Safari makes the text twice as large while the page keeps its width, as the iPhone's aA button does. It runs the same layout checks. Screens that fail today are listed in `tests/ios/known_failures.txt` with the issue that will fix them; a new failure, or a listed screen that now passes, fails the run. `bin/check` runs it on macOS.
- Lighthouse gave the sign-in page 100 for accessibility on 2026-11-07 (phone and desktop). It could not test the signed-in pages (challenge 35).
- Color contrast for calendar chips is pinned by a spec (`spec/serializers/calendar_chip_contrast_spec.rb`).
- Not checked: a screen reader. axe cannot tell whether what a screen reader says makes sense.
- A week on the calendar grows to hold all its entries, so a long entry wrapped onto many lines on a phone is never hidden (#300). `findLayoutProblems` fails on any part of a page, other than a form in a dialog, that scrolls up and down by itself, since a phone shows no scroll bar.
- A button's height comes from a unitless line height, with 36px as its smallest height. With larger text, iOS Safari makes the font bigger but not a height set in rem or em, so a fixed height left the text taller than the button.
- Known failures in iOS Safari: on an iPhone at 200% text, the meal page is 711 pixels wide on a 402 screen, because each of the sign-up table's five columns grows with the text, and the calendar cuts off the day names "Mon" and "Wed" (#301).
- The iPad's and iPhone's Larger Text setting does not change the app's text, because the app does not use the system's text styles (`-apple-system-body`).

## Options

1. An automated accessibility check (axe) on every page in the browser suite, failing on any violation.
2. A by-hand pass with VoiceOver and the keyboard on the calendar and meal pages, with what was found written here.

## History

- 2026-11-07: Opened.
- 2026-11-16: An axe scan of 10 screens found no color contrast failures, so the colors stay. A Tab walk found that a keyboard cannot sign someone up, add a guest, or open anything on the calendar, and that the focus ring is faint or missing. The owner chose: fix those, use one strong focus ring for the keyboard, make axe (option 1) and a Tab walk part of the browser suite. A VoiceOver pass (option 2) is left for the owner.
- 2026-11-16: Built option 1 and the keyboard checks. The sign-up name, the guest menu and the calendar entries became buttons and links, and every page got an h1. axe on all 65 screens also found the menu's "Not saved" text too faint on yellow (now brand red), a link on the crash page shown by color alone (now underlined), day buttons whose names did not hold the number shown, and a rotation bar too small to tap (now 24px tall). Still to do: a VoiceOver pass and 200% text.
- 2026-11-17: Checked 200% text. Two faults found and fixed: the calendar's header was a fixed height, so at narrow widths its links wrapped below the yellow bar and were drawn on top of the Reserve heading (#299); and a calendar entry cut off a word wider than its day ("attending" at 410 pixels). The header now grows with its text, and a long word breaks onto the next line. `tests/e2e/text-size.spec.js` checks nine screens at three widths. Still to do: the VoiceOver pass.
- 2026-11-18: The owner chose to check large text with automated tests only, including in the iPhone and iPad simulators. Fixed: every page now fits 320 pixels wide (only the month grid scrolls sideways), and the calendar forms keep their buttons on screen in short windows. Added `bin/test-ios`, which found #300 and #301; the owner chose to list those screens as known failures, run the check in `bin/check`, and fix #300 (let a week row grow), then #301.
- 2026-11-18: Fixed #300. A week row had a fixed share of the month's height and scrolled by itself, so on a phone the entries past its end were hidden with no scroll bar. Rows now keep their equal share and grow when their entries need more room.
- 2026-11-18: Fixed the text that spilled out of buttons on an iPhone with large text (#301, first part). Buttons now take their height from a unitless line height. Every screenshot at normal text is the same as before.
- 2026-11-18: The calendar's "today" button and month arrows wrap to a second line when they do not fit, so the calendar and the forms over it fit an iPhone at 200% text. When a page is too wide, bin/test-ios now names the elements that reach past the edge.

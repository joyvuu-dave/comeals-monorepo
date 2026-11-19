---
id: 32
title: Everyone can use it
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-19
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
- Large text, by zoom: zooming a page to 200% halves its width in CSS pixels. `tests/e2e/text-size.spec.js` lays out ten screens (login, calendar, meal, closed meal, the four new forms, event edit, rotation) at half the width of an iPad on its side (590), an upright iPad (410) and a laptop (640), and at 320 by 180 (a laptop at 400%, WCAG 1.4.10). It fails when the page is wider than the screen, when two controls are drawn on top of each other, when a box cuts off text or text spills out of a button, link, heading or header bar (`findLayoutProblems` in `tests/helpers/accessibility.js`), or when a form's main button is not on screen without scrolling. The month grid is never narrower than 25rem (400 pixels at normal text); on a narrower screen it scrolls sideways in its own box and the rest of the page fits the width.
- Large text, in iOS Safari: `bin/test-ios` drives real Safari in the iPhone 17 and iPad mini simulators (Xcode, through Apple's safaridriver) against the seeded Rails test server. It opens nine screens at normal text, at 200% text set with `-webkit-text-size-adjust` (in iOS Safari that makes the text twice as large while the page keeps its width, as the aA button in Safari does), and with the device's own Larger Text setting at its largest, set with `xcrun simctl ui <device> content_size`. It runs the same layout checks, checks the root font size the app set for each setting, and fails when larger text makes a form's field narrower than it is at normal text. Screens that fail today are listed in `tests/ios/known_failures.txt` with the issue that will fix them; a new failure, or a listed screen that now passes, fails the run. `bin/check` runs it on macOS.
- Lighthouse gave the sign-in page 100 for accessibility on 2026-11-07 (phone and desktop). It could not test the signed-in pages (challenge 35).
- Color contrast for calendar chips is pinned by a spec (`spec/serializers/calendar_chip_contrast_spec.rb`).
- Not checked: a screen reader. axe cannot tell whether what a screen reader says makes sense.
- A week on the calendar grows to hold all its entries, so a long entry wrapped onto many lines on a phone is never hidden (#300). `findLayoutProblems` fails on any part of a page, other than a form in a dialog, that scrolls up and down by itself, since a phone shows no scroll bar.
- A button's height comes from a unitless line height, with 36px as its smallest height. With larger text, iOS Safari makes the font bigger but not a height set in rem or em, so a fixed height left the text taller than the button.
- When the meal page's sign-up table is wider than its box (on an iPhone at 200% text it is about 711 pixels on a 402 screen), the table scrolls sideways in its own box and the page keeps the screen's width. When it fits, the box does not scroll, so the column headings stay at the top of the screen. `attendees_box.jsx` watches both widths to decide.
- `tests/ios/known_failures.txt` is empty: all 36 screens pass in both simulators.
- The iPhone's and iPad's Larger Text setting changes the app's text (`app/frontend/src/helpers/system_text_size.ts`). The system's body text is 17px at the default setting, so the root's font size is 16px times the system size over 17: 16px at the default, as before. It stops at 200% (32px), the size the checks cover; the largest setting is 312%. Desktop browsers are not changed.

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
- 2026-11-19: Fixed the rest of #301. The owner chose: the sign-up table scrolls sideways in its own box only when it does not fit, and the month grid's smallest width is 25rem, which grows with iOS Safari's text size, so every day name shows in full. The known failures list is now empty. Still to do: a VoiceOver pass, and the iPhone's Larger Text setting.
- 2026-11-19: The owner chose to make the app follow the iPhone's Larger Text setting, and to check it in `bin/test-ios`. Built with the root font size scaled from `-apple-system-body`, so the default setting keeps today's 16px, and capped at 200%. A VoiceOver pass is still to do; it needs a macOS setting that only the owner can turn on.
- 2026-11-19: At large text a form's padding grew with the text and took a third of an iPhone's width, so the fields were about half as wide as at normal text. The padding now stops at its normal-text size, and `bin/test-ios` compares each field's width with its width at normal text.

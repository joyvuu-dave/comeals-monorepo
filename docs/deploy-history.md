# Production deploy history

Every production deploy of the Heroku app since 2014, from the Heroku
release record. Entries were backfilled on 2026-08-17: the change
lists were written by Claude from the commit messages — or, where a
message says almost nothing, from the commit's code — in whichever
repository served production at the time (comeals-rails, comeals2,
comeals-backend, then this monorepo). Newest first. Deploys whose
commits live in this repository have their own GitHub releases and
are only pointed to here. 75 deploys point at commits that no longer
exist in any surviving repository (histories were rewritten); they
are listed as lost.

## v573–v610 (2026-04-09 to 2026-08-04) — this repository

31 deploys from this repository. Each has a GitHub release
(tags `deploy-YYYYMMDD-HHMM`) with a full note.

## v572–v572 (2026-04-09 to 2026-04-09) — lost

1 deploy whose commits survive in no repository we still
have; their histories were rewritten. Only the Heroku record
(version, date, short sha) remains.

## v570–v571 (2026-04-09 to 2026-04-09) — this repository

2 deploys from this repository. Each has a GitHub release
(tags `deploy-YYYYMMDD-HHMM`) with a full note.

## v388–v568 (2018-07-04 to 2026-04-04) — lost

73 deploys whose commits survive in no repository we still
have; their histories were rewritten. Only the Heroku record
(version, date, short sha) remains.

## v387 — 2018-05-28 (comeals-backend, `66002599`)

- Common house reservations can now start at the same time another one ends. Times that touch are no longer counted as a conflict.

## v386 — 2018-05-28 (comeals-backend, `340ed6cc`)

- Removed a timeout that was causing problems.

## v385 — 2018-05-28 (comeals-backend, `cf4bac13`)

- You are now sent to the login page if you are not signed in.
- Pages give up sooner when the server does not answer.

## v384 — 2018-05-28 (comeals-backend, `fe6c8c46`)

- Added space after the "all day" checkbox on the calendar form.
- Changed how the version setting works.

## v383 — 2018-05-28 (comeals-backend, `f7ef97b7`)

- Fixed the time shown in the audit log.

## v382 — 2018-05-28 (comeals-backend, `74eeaea1`)

- Logging out now removes all cookies from your browser.

## v381 — 2018-05-28 (comeals-backend, `1417eb3b`)

- The meal history page now works on iPad.

## v380 — 2018-05-27 (comeals-backend, `f6dcf8b6`)

- The calendar page now works without a type and date in the URL. Going to `/calendar` sends you to `/calendar/all/<today>` (from the code; the message says only "Fixes").
- Signing in and resetting a password now ignore the case of the email address. `Dave@Example.com` finds the same resident as `dave@example.com`.
- The page checks the server version once a minute. It shows the version number on the page, and reloads the page when the server version differs from the one stored in the browser cookie.
- The meal cook list showed wrong data for `reconciled`, `next_id`, `prev_id`, and each resident's attendance. The serializer read those from the wrong record. It now reads them from the meal.
- The calendar picks its start date from the browser URL instead of the router's stored path.
- API requests are now authorized by the `token` parameter only. They no longer fall back to the browser cookie, so a signed-in browser session does not authorize API calls.
- Removed the `GET /api/v1/communities/:id/database` endpoint and its route.
- Updated prettier to 1.13.0, core-js to 2.5.7, rc to 1.2.8, and xpath to 3.1.0.

## v378 — 2018-05-26 (comeals-backend, `301859c5`)

- Fixed a bug where checking for a new version made the page re-render over and over.

## v377 — 2018-05-26 (comeals-backend, `31fc02c4`)

- Rotations now list only residents who can cook. Residents who are inactive, who are not cooks, or whose multiplier is under 2 no longer show up in a rotation.

## v376 — 2018-05-26 (comeals-backend, `461ee578`)

- You now stay signed in where you should be. Every page that needs a login checks for one, and pages that did not check before now do.
- The rotation schedule opens in a modal window instead of its own page.
- Meal history opens in a modal window too.
- Webcal calendar links work again for people whose browser does not have a resident cookie saved.
- The app version now loads after the page, from a new spot in the page, so it shows the right value.
- Updated packages.

## v375 — 2018-05-23 (comeals-backend, `9c0fe261`)

- Pages load faster. The app now fetches related records together in fewer database queries.

## v374 — 2018-05-22 (comeals-backend, `eb246222`)

- Pages load faster. The app now fetches related records in fewer database queries.

## v373 — 2018-05-22 (comeals-backend, `45b21af7`)

- Extras box now updates when you change it. This also fixes a CSS problem on iOS 10.3, caused by the same preload setting that was removed.
- Event times are read correctly now.
- The Calendar button text is darker, so it is easier to read.
- Screen transitions are shorter.
- After you log in, the page reloads instead of redirecting.
- Fixed a React warning about an uncontrolled component, caused by a starting value of null.
- Updated mobx.
- Cleaned up class order.

## v371 — 2018-05-19 (comeals-backend, `145c2bc1`)

- The meal page and the calendar are now one page. You see both without switching pages.
- Event, common house, and guest room edit screens now open as modals on top of the page. The modals are centered.
- The calendar date is now in the page URL. You can link to a day or come back to it later.
- The Today button now works when you click it.
- Fixed a bug where pressing the back button signed you out.
- Fixed navigation between the modals and the sidebar.
- The page no longer fetches the same data twice.
- The page now sets its description tag.
- Removed code that was not used.

## v366 — 2018-05-09 (comeals-backend, `e2ff9c15`)

- The meal list loads faster. Meals are now indexed by date and community.

## v365 — 2018-05-08 (comeals-backend, `3f342cbb`)

- Opening or closing a modal on the calendar no longer reloads the calendar data.

## v364 — 2018-05-08 (comeals-backend, `ed6b94ba`)

- The meal page and the calendar page are now single-page apps. They load new data without a full page reload.
- Pages show a loading indicator while data is being fetched.
- The browser back and forward buttons now work on these pages.
- Creating a new event now happens in a modal window.
- Small changes to the look of the interface.
- Updates now happen in one step, so the page makes fewer requests for data.
- Removed the serializer cache and a leftover console log.

## v363 — 2018-05-01 (comeals-backend, `0973d4d7`)

- You can now edit a meal's title from the Admin page.

## v362 — 2018-04-30 (comeals-backend, `3e10a1e5`)

- Common House reservations now have a title.

## v361 — 2018-04-27 (comeals-backend, `6d756d52`)

- Calendar event titles are no longer cut off. Long titles now show in full.

## v360 — 2018-04-27 (comeals-backend, `7b2a073d`)

- Times now show in your local timezone.

## v359 — 2018-04-27 (comeals-backend, `211ce7b9`)

- Reworded some text on the calendar.

## v358 — 2018-04-27 (comeals-backend, `97dca167`)

- The calendar page now works on small screens like phones and tablets.

## v357 — 2018-04-26 (comeals-backend, `feb13ee4`)

- Removed more unused code. Nothing changes for people using the app.

## v356 — 2018-04-26 (comeals-backend, `a19df590`)

- Fixed the attendee count on meals. It showed the wrong number because of an old cached value.

## v355 — 2018-04-26 (comeals-backend, `069979c7`)

- Fixed a bug where parts of the screen stayed half-hovered.
- Removed the profile code.
- Fixed the build under Node 10 by switching the `upath` dependency to a fork that ships a pre-built file.

## v354 — 2018-04-23 (comeals-backend, `219d7786`)

- Fixed the bill count. It now shows the right number.
- Fixed the guest list. When you delete a guest, the screen now updates correctly.
- Removed code that was not used.
- Formatted the JavaScript files with Prettier.

## v353 — 2018-04-23 (comeals-backend, `d229127e`)

- Pages now load faster. Scripts load only when they are needed, and an old compatibility script was removed.
- The footer is now one shared piece, used by every page.

## v352 — 2018-04-22 (comeals-backend, `f8a5091e`)

- Birthdays now show correctly.

## v351 — 2018-04-22 (comeals-backend, `62031516`)

- Added Skylight to watch how fast the app runs. No visible change for people using the app.

## v350 — 2018-04-22 (comeals-backend, `fe974caa`)

- Chevron arrows now show correctly again.

## v349 — 2018-04-21 (comeals-backend, `9c8b6f53`)

- Fixed a build error that stopped the app from compiling. Some file extensions were removed to fix it.

## v348 — 2018-04-21 (comeals-backend, `4dbddbff`)

- Events now use date picker fields for choosing dates and times.
- Check boxes have a new look, from an upgraded checkbox library.
- Upgraded Rails to 5.2 and Webpacker to 4.0.
- Removed jQuery, Font Awesome, unused packages, and unused files.
- Fixed the code that creates times for events to work with mobx 4, and moved it into one shared method.

## v347 — 2018-04-09 (comeals-backend, `82f98f92`)

- Common House reservations now use your local timezone. Times show the way you set them.

## v346 — 2018-03-29 (comeals-backend, `69edd99e`)

- Adds day and time pickers for choosing a day and a time.

## v345 — 2018-03-25 (comeals-backend, `6d32a2d8`)

- Added a page to reserve the guest room and the common house. You can create, edit, and delete a reservation.
- Deleting a reservation now asks you to confirm first.
- Common house reservation times are now checked. A reservation with bad times is refused.
- The common house cannot be reserved on Mother's Day.
- Changed the color of links.
- Updated the loofah library to fix a security problem.

## v344 — 2018-03-07 (comeals-backend, `ecd7e162`)

- Fixed the vegetarian toggle.

## v343 — 2018-03-07 (comeals-backend, `6103e8e5`)

- The multiplier for each person is now set from their age.

## v342 — 2018-03-07 (comeals-backend, `e9d2bacc`)

- The app no longer blocks a meal from having a third cook. It now shows a warning instead of an error, so you can still sign up.

## v341 — 2018-03-06 (comeals-backend, `33e4cc38`)

- Everyone now gets an email when a new rotation is created.

## v340 — 2018-03-06 (comeals-backend, `5adbdcbd`)

- Residents who have not signed up for an upcoming rotation now get a reminder email. It only looks one week ahead.
- Updated moment.js to a version without a known security problem.
- Updated other package versions, and matched the bundler version Heroku uses.
- Removed npm from package.json.
- A migration updates existing Rotation records.

## v339 — 2018-01-13 (comeals-backend, `00953e9e`)

- The community now has a time zone. Meal times and dates follow it.
- A meal can no longer take a third cook while other meals still need a cook. If you try, the app tells you to sign up for a meal that has no cook.

## v338 — 2017-11-14 (comeals-backend, `c4fbc166`)

- Residents now have a birthday.
- The Rotation page no longer lists inactive residents.

## v337 — 2017-11-13 (comeals-backend, `c22d3d9e`)

- Residents can now be marked active or inactive.

## v335 — 2017-11-13 (comeals-backend, `ab9e1d71`)

- Updated bin stubs.

## v334 — 2017-11-13 (comeals-backend, `b35eda3e`)

- **Security**
  - Blocked access for people who are not allowed in.
- **Admin**
  - Fixed a bug in the admin area.
- **Under the hood**
  - Upgraded libraries.

## v330 — 2017-10-14 (comeals-backend, `455fd5bc`)

- Better cook display when no one has signed up to cook.
- Better logs.

## v329 — 2017-10-06 (comeals-backend, `4397bcef`)

- People who cannot cook no longer show up on the rotation page.

## v328 — 2017-10-06 (comeals-backend, `06c14a59`)

- Adding and removing residents now works correctly in more cases.

## v327 — 2017-10-06 (comeals-backend, `92fc39e3`)

- **Behind the scenes**
  - Logging improved.

## v326 — 2017-10-05 (comeals-backend, `8e729a21`)

- The Cook menu now only lists people who can cook. Guests who cannot cook no longer appear.

## v325 — 2017-10-04 (comeals-backend, `bca27177`)

- Meals are now created a different way.
- Started work on a new React calendar.
- Small change to `create_templates`.

## v324 — 2017-09-17 (comeals-backend, `55567e2b`)

- Signup screens now move between steps with transitions.
- Added basic event support.

## v323 — 2017-09-12 (comeals-backend, `9a73f879`)

- The app no longer crashes when the Heroku environment token is missing or wrong.

## v320 — 2017-09-12 (comeals-backend, `476ece5b`)

- The app now reloads the page when a new version is released, so you always see the current version.
- The calendar shows today with more contrast, so it is easier to spot.

## v319 — 2017-09-10 (comeals-backend, `c102a660`)

- Improved the styling of the rotation display.

## v318 — 2017-09-09 (comeals-backend, `aa44f29e`)

- Screens now change more smoothly while data is loading.
- Updated mobx-state-tree to 0.12.

## v317 — 2017-09-09 (comeals-backend, `5b8b5fe3`)

- Guest counts now update right away for everyone watching the meal.
- Opening and closing a meal now works when you are offline.

## v316 — 2017-09-08 (comeals-backend, `0c044c6b`)

- Fixed a bug in the app's logic.
- Added more tests.

## v315 — 2017-09-08 (comeals-backend, `af27d850`)

- Fixed logic bugs.
- Upgraded to Rails 5.1.4.
- Started adding tests.

## v314 — 2017-09-08 (comeals-backend, `31560763`)

- Fixed a bug with subscriptions.

## v313 — 2017-09-08 (comeals-backend, `b364f186`)

- You can now subscribe to all meals at once.
- Updated the README.

## v312 — 2017-09-07 (comeals-backend, `40951d96`)

- Assets now load from the app itself instead of a CDN.

## v311 — 2017-09-07 (comeals-backend, `bc2c5c0b`)

- Made the menu text bigger on the meal calendar, and kept the rounded corners in the same proportion.

## v310 — 2017-09-07 (comeals-backend, `dc77e731`)

- Fixed a bug on the admin resident page.
- Added an MIT license to the project.

## v309 — 2017-09-06 (comeals-backend, `f5ae7bc5`)

- Fixed a bug that showed up in a rare case.
- Adjusted styling.

## v308 — 2017-09-06 (comeals-backend, `c6bb1153`)

- The calendar subscription file now includes a time zone and a description for each meal.

## v307 — 2017-09-06 (comeals-backend, `9d415742`)

- You can now subscribe to the meal calendar from your own calendar app.

## v305 — 2017-09-05 (comeals-backend, `4e35edec`)

- Changed a log level.

## v304 — 2017-09-05 (comeals-backend, `3ef016ff`)

- Fixed a typo. The commit does not say where.

## v303 — 2017-09-05 (comeals-backend, `5bc6d948`)

- Added Google Analytics to the app, so we can see how people use it.
- Analytics only runs in production. Local development and test work does not send any data.

## v302 — 2017-09-05 (comeals-backend, `567b6114`)

- Upgraded MobX to version 0.11.

## v301 — 2017-09-05 (comeals-backend, `fc0af94d`)

- Fixed the site's layout in Internet Explorer. The screen size rules now work in that browser.

## v300 — 2017-09-05 (comeals-backend, `f406c047`)

- Fixed the app on Internet Explorer. It used a number function that IE does not have.
- Bumped the version.

## v299 — 2017-09-04 (comeals-backend, `03497d93`)

- Added a polyfill for Promises, so the app works in older browsers.

## v297 — 2017-09-04 (comeals-backend, `ebc1b52c`)

- Updated the app version number.
- Kept the npm version pinned in the package config.

## v296 — 2017-09-04 (comeals-backend, `1541080f`)

- Upgraded to rails/webpacker 3.0.
- Shoelace now comes from npm instead of being vendored, at version 1.0.0.beta22.
- Pinned the yarn version and added a version field to package.json.

## v293 — 2017-08-30 (comeals-backend, `25e5f012`)

- Fixed a bug in how the rotation was shown.

## v292 — 2017-08-30 (comeals-backend, `b372f54f`)

- Fixed rotation colors. They were set wrong, and the first fix did not work, so a second change corrected it.

## v291 — 2017-08-30 (comeals-backend, `77f8b33a`)

- Fixed creating a rotation.

## v290 — 2017-08-30 (comeals-backend, `d47ff9b6`)

- The count of vegetarian guests on a meal is now correct. Before, every guest was counted as vegetarian; now only guests marked vegetarian are counted. (From the code — the message only says "Fix #9".)

## v289 — 2017-08-29 (comeals-backend, `fdc1cff3`)

- Dates on admin pages now use new styling.

## v288 — 2017-08-29 (comeals-backend, `3e95d4dd`)

- Admin pages no longer show "NaN" where a number should be.

## v287 — 2017-08-29 (comeals-backend, `7d562a48`)

- Cooks can now be saved with the "can cook" setting from the form. The field was being dropped before, so the choice did not stick.

## v286 — 2017-08-29 (comeals-backend, `28ace352`)

- Admins now get a real logout. Clicking Logout in the admin area deletes the admin "remember me" cookie, clears the session, and sends you to the main site. Before this, Logout only sent you to the root URL (from the code; the message says only "Fixes #8").
- Added a new admin page at `/admin-logout` on the admin subdomain that does this logout.

## v285 — 2017-08-29 (comeals-backend, `015dcf6e`)

- Children no longer get an email address.

## v284 — 2017-08-29 (comeals-backend, `37938f2b`)

- Children can now be added without an email address.

## v283 — 2017-08-29 (comeals-backend, `0e7f491d`)

- Signups, cook signups, and cancellations now show up on everyone's screen right away. You no longer need to reload the page to see what other people did.

## v282 — 2017-08-28 (comeals-backend, `34c384a6`)

- Seed data changed.
- Records are now filtered by community.

## v281 — 2017-08-28 (comeals-backend, `70e0ee6e`)

- Cleaned up the layout of the rotation page.

## v280 — 2017-08-28 (comeals-backend, `88b0c88f`)

- Add rotations. Cooking schedules are now part of the app.

## v279 — 2017-08-23 (comeals-backend, `4723ddeb`)

- Calendar events now show their title.

## v278 — 2017-08-23 (comeals-backend, `40553c03`)

- Meals that have been reconciled are now locked. You cannot change them after they are settled.

## v277 — 2017-08-23 (comeals-backend, `b72671ac`)

- Guests and attendees can now be removed only when it is allowed. Removal is offered based on the current meal, not in every case.

## v276 — 2017-08-19 (comeals-backend, `2bb43dbd`)

- Guest code was reorganized. No change to how guests work for people using the app.

## v275 — 2017-08-17 (comeals-backend, `d8d7cdbd`)

- Fixed the see-through look on part of the app.

## v274 — 2017-08-17 (comeals-backend, `536d37fa`)

- Fixed the text boxes on iPhone and iPad. They now use the app's own styling instead of the browser default.

## v273 — 2017-08-17 (comeals-backend, `ba87d7fb`)

- Fixed a display problem in Safari and other WebKit browsers, where something did not fade in or out correctly.

## v272 — 2017-08-17 (comeals-backend, `8f8452e0`)

- Fixed styling problems on mobile screens.

## v271 — 2017-08-16 (comeals-backend, `4ec35b34`)

- Changed CSS styling.

## v270 — 2017-08-16 (comeals-backend, `63667a8a`)

- Residents now show which unit they live in.
- Resident lists are now sorted by name.

## v269 — 2017-08-16 (comeals-backend, `e18e4b41`)

- Page transitions now wait longer before timing out, so slower loads finish instead of failing.
- The admin pages use the earlier styling again.

## v268 — 2017-08-15 (comeals-backend, `41a99935`)

- Resident balances are now saved, so each person's balance stays the same between visits instead of being worked out fresh each time.

## v267 — 2017-08-15 (comeals-backend, `1eabfa8e`)

- Set a minimum width on the header, so it no longer shrinks and breaks its layout on narrow screens.

## v266 — 2017-08-15 (comeals-backend, `62bcb445`)

- Made pages load faster by sharing common code between them.
- Cleaned up the styles.

## v265 — 2017-08-14 (comeals-backend, `f37600d3`)

- Removed unused code and cleaned up styling.

## v264 — 2017-08-13 (comeals-backend, `08b6e474`)

- Calendar data now refreshes on its own every minute, so the page stays up to date without a reload.

## v263 — 2017-08-13 (comeals-backend, `4575e0e1`)

- Logging out is more reliable. Clicking logout now waits 100 milliseconds before sending you to the home page, so the browser has time to delete the login cookie first. (From the code; the commit message only says logout was "still acting up.")

## v262 — 2017-08-13 (comeals-backend, `9c0022c4`)

- Improved the arrows.

## v261 — 2017-08-13 (comeals-backend, `1b3b0bd8`)

- **Fixes**
  - Logging out should work now.

## v260 — 2017-08-13 (comeals-backend, `3d0ceadd`)

- Fixed the buttons for meal preferences. They are now enabled and disabled at the right times.

## v259 — 2017-08-13 (comeals-backend, `1bfe9a7f`)

- Added helper text to the attendee sign-up table: the "Name" column header now says "(click to add)" in small gray italic text, so people know they can click a name to add that person.

## v258 — 2017-08-13 (comeals-backend, `d17f120c`)

- Made styling and behavior changes based on feedback from users.

## v257 — 2017-08-12 (comeals-backend, `9bb596db`)

- You can log out again. The logout button was broken.
- Set the app's slug size.

## v256 — 2017-08-12 (comeals-backend, `6b9072d1`)

- **Style**
  - Small visual style changes.

## v255 — 2017-08-12 (comeals-backend, `ad60639e`)

- Changed some wording in the app.

## v254 — 2017-08-12 (comeals-backend, `6a2eb720`)

- You can add yourself to a meal and remove yourself from a meal again. The buttons now do the right thing.
- The calendar looks different. Its display was updated.

## v253 — 2017-08-12 (comeals-backend, `ddadc06d`)

- Sample data now sets a maximum number of people on some meals, so demo and test setups show meals with a cap.

## v252 — 2017-08-12 (comeals-backend, `36ba9d82`)

- The logout button is easier to see. It now has better contrast against the background.

## v251 — 2017-08-12 (comeals-backend, `30c4620f`)

- Updated the Shoelace library the app uses.

## v250 — 2017-08-12 (comeals-backend, `2c8dc882`)

- The footer is smaller.

## v249 — 2017-08-12 (comeals-backend, `57bd0d36`)

- Text fields no longer capitalize the first letter automatically on iOS.

## v248 — 2017-08-12 (comeals-backend, `b17b3cd4`)

- The "remember me" box on the login page is now checked by default.

## v247 — 2017-08-12 (comeals-backend, `9c61832b`)

First deploy tracked from comeals-backend; the deploy before it came
from a different repository, so there is no commit range to
describe.

## v197–v246 (2017-08-05 to 2017-08-12) — this repository

38 deploys from this repository. Each has a GitHub release
(tags `deploy-YYYYMMDD-HHMM`) with a full note.

## v195 — 2017-03-09 (comeals-rails, `76fec5e`)

_Re-deploy of the same code; no changes._

## v194 — 2017-03-09 (comeals-rails, `76fec5e`)

- The calendar and the panel next to it now split the window evenly. Before, the calendar took three quarters of the width and the panel one quarter.
- The page is now much wider. The container went from 1200–1600px to 1800–3600px, so the app needs a wider screen.
- The meals and bills APIs now return every record when no start and end date are given. Before, a request without dates returned nothing (from the code; the message says only "progress").
- Switched the money-rails gem back to the released version instead of a fork.
- Updated Rails from 5.0.1 to 5.0.2 and many other gems (counter_culture, uglifier, puma, faker, and others).
- Removed an empty test file for the calendar controller.

## v193 — 2017-02-02 (comeals-rails, `bb7dfd9`)

_Re-deploy of the same code; no changes._

## v192 — 2017-02-02 (comeals-rails, `bb7dfd9`)

- The calendar now shows on every page. It sits on the left, and the page content sits in a narrow column on the right. Before, the calendar had its own page reached from a "Calendar" button in the header. That button is gone. (from the code)
- The home page now opens the current meal form instead of the calendar page.
- The report page shows a spinner next to "Residents" and next to "Units" while that data loads. The spinner stops when the data arrives. (from the code)
- The meal page now lists the names of the residents signed up for that meal.
- The "Back" and "Edit" buttons are gone from the meal page. Only "Delete" is left.
- The login page no longer shows the big box with the community name and the line about co-housing in Old Oakland.
- Lists that use paging now show 5 rows per page instead of 25.
- The page is now at least 1200 pixels wide and at most 1600 pixels wide.
- The meals list page title is now smaller.
- The meals and bills API endpoints now require a start and end date, and return only records in that range. Before, they returned all records. (from the code)
- Opening a meal form with no id no longer redirects to the current meal's edit page. The redirect line is commented out. (from the code)
- Updated autoprefixer-rails to 6.7.2, rack-cors to 0.4.1, and the git versions of rails, active_model_serializers, and annotate.

## v191 — 2017-01-30 (comeals-rails, `0bc2eb5`)

- Meal forms and lists no longer require you to be signed in. The sign-in check on the meals pages is turned off (from the code; the message says nothing).
- After you create or update a bill, create meal templates, or update a meal, the app now sends you to the home page instead of the calendar page. The Cancel button on the meal form also goes to the home page now.
- Updated gems: Rails on the 5-0-stable branch, Puma 3.6.2 to 3.7.0, autoprefixer-rails 6.7.0 to 6.7.1, and a newer minimum for rails-html-sanitizer (1.0.2 to 1.0.3).

## v190 — 2017-01-27 (comeals-rails, `12b7cf2`)

_Re-deploy of the same code; no changes._

## v189 — 2017-01-27 (comeals-rails, `12b7cf2`)

- The site now signs you in as yourself. Instead of one shared "admin" or "user" login, you pick your name from a list on the login page. The list shows unit and name, and marks admins with a star.
- Residents can have a password. If a resident has no password set, picking the name signs them in with no password. If a resident has a password, the password is required.
- Admin rights now belong to a resident. Each resident has an admin flag, and admins must have a password (from the code; the message says nothing).
- The header now shows "Log Out" with your name, and "(admin)" if you are an admin. When you are signed out, it shows a "Log In" button instead.
- The calendar is now the home page. The old start page is gone, and the `/calendar` address was removed.
- The calendar page shows a spinner while events load. It stops once all events are drawn.
- The login page shows the community name and description.
- Signing in or out shows a message saying who signed in and whether a password was used.
- The bill form now labels the amount field "Amount" instead of "Amount cents".
- The calendar page and the meals and bills API no longer require you to be signed in (from the code; the message says nothing).
- CSRF protection is turned off: `protect_from_forgery` is commented out and the origin check is set to false (from the code; the message says nothing).
- The login list contains two placeholder options, "Blank" and "foo" with id -1, that look like leftover test code (from the code).
- Gem updates: bcrypt added for password hashing, bootstrap-sass to 3.3.7, kaminari to 1.0.1, plus smaller updates to autoprefixer-rails, diff-lcs, rb-inotify, spring, tilt, and websocket-driver.
- Simple Form now supports a minlength attribute on inputs.
- Seed data now gives half the residents the password "password" and makes about one in seven an admin.

## v188 — 2017-01-18 (comeals-rails, `c073df4`)

- Fixed the reimbursable amount on a bill. It now rounds up to a multiple of the bill's own multiplier, not the meal's multiplier (the commit message says only "fix bug", so this comes from reading the code).
- Changed the second amount calculation on a bill: the share of the meal cost is now multiplied by the bill's amount in cents instead of by 100.

## v187 — 2017-01-18 (comeals-rails, `84ca628`)

- Calendar meal titles are new. A future dinner shows "Dinner: 12 max (3 left)" when the meal has a max, or "Dinner: no max" when it does not. A past dinner shows "Dinner: 12 present". (from the code; the commit message says only "Progress")
- Meal titles now show the meal id in parentheses when the meal's money does not balance, with a `*` added when the meal is subsidized.
- Cook names on the calendar are now short. A cook shows as just a first name when that first name is unique among residents, or as "First L" when it is not. The word "Cook" was removed from the title, and a cook who billed $0 shows only a name, with no amount.
- Meal cost math was rewritten. The per-person cost is now the sum of each bill's own per-person cost, instead of one number worked out from the meal's total cost. Guest and resident charges use this new number.
- The rules that blocked a bill from being saved were removed. A bill no longer fails to save when nobody has signed up yet, or when the meal cost would go over the cap.
- Notifications (notie) now load from a CDN instead of from the app's own files. The bundled copy was deleted.
- Seed data changed: every resident gets a first and last name, three residents share the same first name, some meals get a $0 bill next to a large one, and meal max is now a random number from 0 to 3 above the number of people signed up.
- Rails, builder, and ffi were updated to newer versions.

## v186 — 2017-01-13 (comeals-rails, `4efa2a2`)

- Added a CodeBeat badge to the project README. No changes to the app itself.

## v185 — 2017-01-13 (comeals-rails, `1cbab30`)

- Bills now check what you enter before saving.

## v184 — 2017-01-13 (comeals-rails, `f132ac8`)

_Re-deploy of the same code; no changes._

## v183 — 2017-01-13 (comeals-rails, `f132ac8`)

- Fixed a bug in authorization and the cap.

## v182 — 2017-01-13 (comeals-rails, `21ed65c`)

- Meals now count their bills. A new `bills_count` column on meals is kept up to date automatically (from the code; the message says only "Improvements").
- The per-person charge for a meal is worked out differently. It is 0 when the meal has no cost or no attendees. Otherwise the cost is divided by the number of attendees, rounded up, and then raised until it divides evenly by the number of attendees, but not past the cap. If no such value exists below the cap, the method returns nothing at all, which is a bug.
- The reimbursement amount on a bill changed. For a subsidized meal it is now the whole meal's overage (`cost - cap * multiplier`), not that bill's share of it. For a meal that is not subsidized, the bill amount is rounded up until it divides evenly by the number of attendees.
- A new check, `Meal.can_add_bill`, says a bill may be added when the meal has no bills yet, or when its cost is still under `cap * multiplier`. It is written as a class method but reads per-meal fields, so calling it raises an error. This is a bug.
- The calendar was updated from FullCalendar 2.7.2 to 3.1.0. Support for old Internet Explorer was dropped in that version, drag and select behavior changed, and a footer bar option was added.
- The app now loads jQuery 3 instead of jQuery 2, and the unminified moment.js instead of the minified one.
- Rails was updated to a newer commit on the 5-0-stable branch, and rake to 12.0.0.
- The `annotate` gem now comes from the `develop` branch on GitHub. The rake task that writes schema comments was replaced with the gem's own tasks and a full options list. Model, serializer, spec, and factory files were re-annotated: they show the new schema version, the new `bills_count` column, and foreign key names shortened to `fk_rails_...`.
- Seed data now creates meals for September 2016 through April 2017 instead of 2016 dates.

## v180 — 2017-01-11 (comeals-rails, `e7d1f07`)

_Re-deploy of the same code; no changes._

## v179 — 2017-01-11 (comeals-rails, `e7d1f07`)

- Fixed the bill list page.
- Updated dependencies.

## v177 — 2016-05-22 (comeals-rails, `6559c97`)

_Re-deploy of the same code; no changes._

## v176 — 2016-05-22 (comeals-rails, `6559c97`)

- Fixed the bills index page.
- Removed the notie library. An earlier change had added it; this change undoes it.
- Removed unused code.
- Updated libraries and regenerated the generated files.

## v175 — 2016-04-30 (comeals-rails, `a36acff`)

- Rotation length now shows in a clearer format.

## v174 — 2016-04-26 (comeals-rails, `7af5060`)

- Bills and costs now use the money_rails gem to handle amounts.

## v173 — 2016-04-26 (comeals-rails, `fe3b72e`)

_Re-deploy of the same code; no changes._

## v172 — 2016-04-12 (comeals-rails, `19e11c8`)

- Started building the app's interface in React.

## v171 — 2016-03-01 (comeals-rails, `fe3b72e`)

- Meal signups now have a vegetarian option and a late option. You can mark whether you want a vegetarian meal and whether you will arrive late.
- The amount column is gone from meal signups.
- Added a test page.
- Upgraded the gems the app is built on.

## v170 — 2016-02-23 (comeals-rails, `d6fb0a7`)

- Money amounts now use the money-rails library.

## v169 — 2016-02-18 (comeals-rails, `2678215`)

_Re-deploy of the same code; no changes._

## v168 — 2016-02-18 (comeals-rails, `2678215`)

- Meal signups now work when the cost cap is not set. Before, people could not sign up until an admin set a cap.
- Admins can enter the rotation length.

## v167 — 2016-02-18 (comeals-rails, `7d80382`)

- You can now edit a meal's max signups and description.

## v164 — 2016-02-17 (comeals-rails, `55f6c4a`)

- Made the info button a different color.

## v163 — 2016-02-17 (comeals-rails, `e27c24f`)

- Added the Faker library to production.

## v162 — 2016-02-17 (comeals-rails, `d65c1ec`)

- Updated a gem.

## v157 — 2016-02-14 (comeals-rails, `e9b12d6`)

- The app now allows requests from other web addresses (CORS enabled).
- The spinner was removed.
- Controller actions were merged together, so the same work is now handled in fewer places.

## v156 — 2016-02-12 (comeals-rails, `de69886`)

- Guest count: this changed. The commit does not say what changed about it.
- Fade in: something now fades in. The commit does not say what.
- Strikethrough: strikethrough was added or changed somewhere. The commit does not say where.
- Max: a maximum was added or changed. The commit does not say for what.

## v155 — 2016-02-12 (comeals-rails, `59ed16c`)

- Added tooltips to the calendar.

## v154 — 2016-02-12 (comeals-rails, `0f3c784`)

- Meal date fields on the meal page now line up with the other fields. The rule that removes left and right margins on guest name, description, and bill amount fields now also covers the meal date field (from the code; the message says only "styling").

## v153 — 2016-02-12 (comeals-rails, `e67ac9c`)

- Records that are part of a finished reconciliation can no longer be changed.
- Forms now have next and previous buttons to move between records.
- If you leave a form with unsaved changes, the app now asks you to confirm first.

## v146 — 2016-02-10 (comeals-rails, `3422f0b`)

- Set up the memcached configuration for production.

## v145 — 2016-02-10 (comeals-rails, `97ae8c7`)

- Meals now have a description.

## v144 — 2016-02-10 (comeals-rails, `f8e5519`)

- Added reconciliation. You can now settle up a set of meals and see what each person owes or is owed.

## v143 — 2016-02-10 (comeals-rails, `cd70a32`)

- Reports are now built in React. This changes how the report page is drawn in the browser.
- Added the `react_on_rails` gem and the first React setup, so the app can use React components.
- Merged the `master` branch into this work before the deploy.

## v142 — 2016-02-09 (comeals-rails, `1f06c25`)

- Added an admin page that can auto-generate meal templates.
- Fixed the test suite.

## v141 — 2016-02-08 (comeals-rails, `f5b0b61`)

- Set up the app to run on Heroku. Added the Heroku gem and a Procfile.

## v140 — 2016-02-08 (comeals-rails, `cecd52d`)

First deploy tracked from comeals-rails; the deploy before it came
from a different repository, so there is no commit range to
describe.

## v133 — 2015-07-19 (comeals2, `5b9cc49`)

**Behind the scenes**

- Updated a gem. No user-visible changes.

## v125 — 2015-06-27 (comeals2, `56964a4`)

- Bills for reconciled meals now update in the background, so the page does not wait for them.
- Units now show the accurate balance.

## v123 — 2015-06-27 (comeals2, `e2946a3`)

- Bills tied to a meal now update when the meal changes. This happens inside the callback that was already there.

## v120 — 2015-06-27 (comeals2, `e85619d`)

- Bills now update when a meal is reconciled.

## v119 — 2015-06-27 (comeals2, `4019cdd`)

- Updated the gems the app uses to newer versions. No visible change.

## v118 — 2015-06-02 (comeals2, `02de1eb`)

- Only a superuser can edit.

## v117 — 2015-05-31 (comeals2, `ed1fd11`)

- Fixed counts that were wrong in some places. The app now counts records directly instead of using a cached number.

## v116 — 2015-05-31 (comeals2, `7e10237`)

- Fixed an error for residents whose balance had never been updated. The app now handles a missing "balance last updated" time instead of failing.

## v115 — 2015-05-31 (comeals2, `1e5aab4`)

- Search engines can index the site again.
- Meal cost math now runs only when it is needed, which cuts extra work. The API changed as part of this.

## v108 — 2015-05-26 (comeals2, `33bc940`)

- Meal costs now use the multiplier saved on each meal signup, not the resident's current multiplier. A resident's cost for a past meal no longer changes when their multiplier changes later. (From the code; the message says "updates".)
- Each meal signup now stores the resident's multiplier when it is saved.
- A meal's total multiplier now counts every signup row for that meal, including duplicates. Before, it counted each resident once.
- In the admin area, the meal list on the dashboard and the meal picker on the bill form now show the newest date first.
- Bills no longer run the reconciled update when a bill is deleted. It runs only on create and update.
- Updated the mime-types gem from 2.5 to 2.6.1.

## v107 — 2015-05-26 (comeals2, `20bce90`)

- Meals now track a multiplier for each resident, so a person can count as more than one serving.

## v105 — 2015-05-25 (comeals2, `988606d`)

- Upgraded the app's hosting stack to Heroku Cedar-14.

## v104 — 2015-05-25 (comeals2, `0953593`)

- Search engine crawlers are now blocked from the site. They used up free server time.

## v103 — 2015-05-25 (comeals2, `0b742e0`)

- Each bill's amount now shows on the meal record.
- Upgraded the app to Rails 4.2, which also removed a deprecation warning.
- Updated the gems.
- Updated the Travis config to a new version.

## v97 — 2014-09-03 (comeals2, `eb5e6b8`)

- Fixed guests. A guest is now linked to the resident who signed them up, using the right field.

## v96 — 2014-08-27 (comeals2, `a84ef0e`)

- Went back to Rails 4.1.1.

## v95 — 2014-08-27 (comeals2, `f66ac31`)

- Cleaned up the database migration files by combining them into fewer files. Nothing changed for people using the app.

## v90 — 2014-08-27 (comeals2, `4248615`)

- Updated a gem.

## v89 — 2014-08-23 (comeals2, `ec8b57c`)

- Meals now show whether they have been reconciled.

## v88 — 2014-08-23 (comeals2, `2d46f55`)

- Added reconciliations. A reconciliation is a new record in the app.

## v87 — 2014-08-23 (comeals2, `4fd770e`)

- Updated gem dependencies.

## v86 — 2014-08-20 (comeals2, `3ece1d6`)

- Internal: updated gem versions. No user-visible changes.

## v85 — 2014-08-20 (comeals2, `029ee39`)

- Resident pages now show the price category for each hosted guest.

## v84 — 2014-08-20 (comeals2, `0f5f6d3`)

- Resident pages now list the guests that resident hosted.

## v83 — 2014-08-19 (comeals2, `cea5727`)

- **Behind the scenes**
  - Removed a database migration that was failing.

## v82 — 2014-08-19 (comeals2, `3c6db69`)

**Behind the scenes**

- Removed foreign keys from the database.

## v81 — 2014-08-19 (comeals2, `d74b646`)

- Units and residents now have friendly URLs that use names instead of ID numbers.

## v80 — 2014-08-19 (comeals2, `c692f38`)

- Styling updates.

## v79 — 2014-08-19 (comeals2, `74b97b3`)

- Money amounts now show a dollar sign.

## v78 — 2014-08-19 (comeals2, `230a4b6`)

- Added a "Fork me on GitHub" link to the site.

## v77 — 2014-08-19 (comeals2, `44fad7c`)

- Bills and meals lists now show the newest first, sorted by date.
- Pagination links now show the total number of records.

## v76 — 2014-08-19 (comeals2, `6466f15`)

- The meal list now shows how many bills each meal has.
- Bill dates now show in the right format.

## v75 — 2014-08-19 (comeals2, `87e290d`)

- Upgraded the app to Rails 4.1.5. Foreign keys were removed from the database to make this possible. No change you can see in the app.

## v74 — 2014-08-19 (comeals2, `f9e37cb`)

- Upgraded the Sass tools so the app can use Sass 3.4. No user-visible change.

## v73 — 2014-08-19 (comeals2, `e0cabac`)

- Added rack-zippy to serve static files.

## v72 — 2014-08-19 (comeals2, `4e6165f`)

- Pages load faster. The server now compresses what it sends.

## v71 — 2014-08-19 (comeals2, `213429c`)

- The web server now starts correctly. The Procfile called `thin` without the `start` command; it now runs `thin start` (from the code — the message says only "start thin").

## v70 — 2014-08-19 (comeals2, `6adfd66`)

- Switched the web server to Thin.

## v69 — 2014-08-19 (comeals2, `19379b9`)

- The app no longer shows admin pages to people who are not admins.
- Average meal cost moved to a new spot on the page.
- The footer can now be overridden.
- The server that runs the app in production changed from unicorn to thin, and the request timeout tool (rack-timeout) was removed, along with its config file.

## v68 — 2014-08-19 (comeals2, `8c3a0dc`)

- Updated a gem.

## v67 — 2014-08-19 (comeals2, `4ddc76f`)

- Bills now record whether they have been reconciled.
- Meal models show totals and the average meal cost.
- Models are annotated automatically.
- Fixed the case where there are no meals, which the totals and average meal cost could not handle before.

## v66 — 2014-08-08 (comeals2, `9370e05`)

- Bills now appear on a resident's page.

## v65 — 2014-08-08 (comeals2, `9e6155c`)

- Fixed the cost per adult calculation.

## v64 — 2014-08-08 (comeals2, `964c085`)

- Meal and signup pages now have detail views, so you can open one item and see everything about it.
- Lists can be sorted.
- Behind the scenes: the app now builds its API responses with active_model_serializers.
- Updated the New Relic gem.
- Automatic deploys are turned off. Deploys now happen by hand.

## v63 — 2014-07-22 (comeals2, `ac4eb5c`)

- Pages now wait 14 seconds before they give up, instead of the old shorter limit.

## v62 — 2014-07-21 (comeals2, `45410ed`)

- Adding a guest with no information no longer creates a blank guest record. The app now ignores it.
- Adding a guest without a host no longer creates a record with no host. The app now ignores it.
- Updated gem versions.

## v61 — 2014-07-16 (comeals2, `9429c2b`)

- Errors now show a custom 500 page instead of the default one. Each error log includes a UUID, so a report can be matched to the log.
- Fixed bills getting the wrong date. The date now comes from the meal, not from when the bill was entered.
- The request timeout was raised to 15 seconds, then set back to 10 seconds. No net change.

## v60 — 2014-07-14 (comeals2, `806b051`)

- Updated a gem.

## v59 — 2014-07-14 (comeals2, `2c726a2`)

- Bill list and Bill edit page now show meal dates with the day of the week, like "Mon, Jul 14 2014". This code was there before but was turned off because it showed the wrong day. It now adds one day to correct that, and is turned on again (from the code; the message only says "fix date problems").
- The admin dashboard no longer shows the empty welcome box. It now shows three lists side by side: units by name, residents by name, and meals by date (from the code).
- Updated the ActiveAdmin library to a newer version.
- Cleaned up spacing and quote style in the admin files and models, and moved private methods to the normal indent level. No behavior change.

## v58 — 2014-07-14 (comeals2, `e78d9dd`)

- Bills now load their dropdown without moment.js.

## v57 — 2014-07-14 (comeals2, `e2d3f70`)

- Went back to the earlier version of Rails. The upgrade to Rails 4.1.4 was undone.

## v56 — 2014-07-14 (comeals2, `4b3503a`)

- Text you type in forms no longer keeps extra spaces at the start or end. Every field is trimmed before it is saved.
- Bill dates are shown as plain dates again. The date formatting on bills is turned off.
- Updated gem versions.

## v55 — 2014-06-14 (comeals2, `24f36fa`)

First deploy tracked from comeals2; the deploy before it came
from a different repository, so there is no commit range to
describe.

## v54–v54 (2014-06-14 to 2014-06-14) — lost

1 deploy whose commits survive in no repository we still
have; their histories were rewritten. Only the Heroku record
(version, date, short sha) remains.

## v52 — 2014-06-14 (comeals2, `fbd9f09`)

- Added Travis CI to run the test suite on each push, and put a build badge on the README.
- Added Coveralls to track test coverage.
- Bumped uglifier.
- Stopped tracking SimpleCov output files in git.

## v51 — 2014-06-12 (comeals2, `2cb9215`)

- Updated a gem.

## v50 — 2014-06-11 (comeals2, `f71b05f`)

- Updated gem versions and added comments. No user-visible changes.

## v49 — 2014-06-10 (comeals2, `a1cbbbe`)

- Added Memcachier for caching.

## v45 — 2014-06-10 (comeals2, `44e0f42`)

- Removed the comments table from the admin pages.

## v43 — 2014-06-10 (comeals2, `cf6197b`)

- Updated the gems the app depends on. Nothing changes for people using the app.

## v42 — 2014-06-08 (comeals2, `12b6325`)

- Admin accounts can no longer be edited.
- Lists now show 10 items per page.

## v41 — 2014-06-08 (comeals2, `3e2ef1b`)

- Fixed image and asset URLs so they include the subdomain in the host.

## v38 — 2014-06-08 (comeals2, `9b87631`)

- Emails from the app now come from a different sender address.

## v37 — 2014-06-08 (comeals2, `b705809`)

- People can now create their own account. Sign up is part of the app.
- New accounts get a confirmation email. You click the link in it to confirm your address.
- Email links now point at the right site. The mailer is told which host to use, so the confirmation link works.
- If an email address is rejected at sign up, the form now says why.
- Fixed a syntax error in the code.

## v36 — 2014-06-08 (comeals2, `185d482`)

- Fixed the date code to use the current moment.js syntax instead of an old one that is no longer supported.

## v35 — 2014-06-08 (comeals2, `1e414c9`)

**Meals**

- Meals are now listed in date order.
- You can see which meals a resident attended.
- Only one meal can exist for a given day.

**Signups**

- Each resident can only sign up once for a Swansway meal.
- A guest's name must be unique for a meal and host, so the same guest can't be added twice.

**Bills**

- A bill must be more than 1¢.
- A resident can only have one bill per meal.

**Residents**

- Resident names must be unique.

**Forms**

- The form clears when the value is 0.

**Under the hood**

- Updated gems.
- Added profiling in development mode.
- Models now use instance variables.

## v34 — 2014-06-01 (comeals2, `0c6b31b`)

- The calendar now shows the year.

## v33 — 2014-06-01 (comeals2, `85c58ff`)

- Bill list now shows the unit name for each bill.

## v32 — 2014-06-01 (comeals2, `9febf75`)

- Only adults can have bills now. A child can no longer be listed as the person who paid for a meal.

## v31 — 2014-06-01 (comeals2, `aabdd1a`)

- Meals now show a cost per adult.

## v30 — 2014-06-01 (comeals2, `dd9d664`)

- Each meal now shows the cost per person.

## v29 — 2014-06-01 (comeals2, `b4aa9cd`)

- **Fixes**
  - Adding a guest works again. Some checks on the guest form stopped the guest record from being saved when it was created as part of another form. Those checks were removed.

## v28 — 2014-06-01 (comeals2, `f0df4c7`)

- The host dropdown now lists names in alphabetical order.

## v27 — 2014-06-01 (comeals2, `a3c3f07`)

- Units now appear in order by name.
- When you open the unit form, the cursor starts in the name field.

## v26 — 2014-06-01 (comeals2, `b7a18ad`)

- The residents page now puts the cursor in the name field when it opens. You can type a name right away.

## v25 — 2014-06-01 (comeals2, `c977862`)

- Fixed the cost calculation for a resident's meal charges. The method that adds up guest costs did not return its result (from the code; the message only says "return the result").

## v24 — 2014-06-01 (comeals2, `163792e`)

- Unit names must now be unique. Saving a unit with a name that another unit already uses is refused.

## v20 — 2014-06-01 (comeals2, `969132c`)

- Meals now track guests. You can add guests to a meal.
- Updated gem versions.
- Replaced the old migrations with a single migration. This was needed to regenerate models that were added and removed earlier. No change to how the app works.

## v15 — 2014-05-28 (comeals2, `e1a7e5e`)

- Removed bundled gems from the repository and added them to `.gitignore`, so the checkout is smaller.
- Fixed the `.gitignore` file, which had a wrong entry.
- Renamed `README.rdoc` to `README.md` and rewrote it in Markdown, with several later edits.

## v14 — 2014-05-28 (comeals2, `f42b1c9`)

- Emails now go out through Postmark.

## v12 — 2014-05-28 (comeals2, `c0b9ea3`)

- Foreigner is now visible in production.

## v11 — 2014-05-28 (comeals2, `513032a`)

First deploy tracked from comeals2; the deploy before it came
from a different repository, so there is no commit range to
describe.

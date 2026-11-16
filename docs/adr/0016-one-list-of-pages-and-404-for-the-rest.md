# ADR 0016: One list of the app's pages, and a 404 for every other address

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

Until this change, the server sent the resident app, with status 200,
for every address on the resident site that was not an API or admin
address. The app then decided what to show. So
`/.well-known/security.txt`, `/settings.py` or `/foo.json` got 200 and
an HTML page. A program that asked for one of those files read the page
as the file. Lighthouse did this on 2026-11-07 (challenge 34).

The app also had a login route, `/:modal?/:token?`, that matched any
address of one or two parts. So `/foo` showed the login page.

## Decision

1. **One list.** `app/frontend/src/routes.json` lists the pages of the
   resident app: a name, a pattern in React Router's syntax, and at
   least one example address for each. The app makes one `<Route>` for
   each entry (`components/app/app_routes.tsx`), and the server reads
   the same file (`lib/app_pages.rb`). A pattern with `*` is refused,
   because it would make every address under it a page.

2. **The server answers 404 for every other address.** On the resident
   site, an address that matches a pattern gets the app with status 200
   (`FallbackController#index`). Every other address gets the plain
   `public/404.html` with status 404 and `Cache-Control: no-store`
   (`FallbackController#not_found`). The API and the admin site do not
   change. The rule is in `config/routes.rb`.

3. **The login pages are exactly `/`, `/reset-password` and
   `/confirm-email`.** The code for the old `/reset-password/<token>`
   link is removed. Those links stopped being sent on 2026-10-23, and a
   reset token lasts 24 hours, so none still works. Old addresses from
   2017 and 2018 (`/calendar`, `/create-community`) are not kept.

4. **A missed page is loud.** If a page is ever missing from the list,
   the server answers its address with the plain 404 page, and the app
   does not load. Someone sees that at once. The other choice was to
   send the app with status 404, so a missing page would still work for
   a person. The owner chose loud, and many guards (below) so that it
   does not happen.

5. **The app has a `*` route** that shows "Page not found" with a link
   to `/`. The server never sends the app for such an address, so the
   app shows it only when the app itself moves to an address that is not
   a page.

## Why the server copies React Router's rules

The server must answer 200 for exactly the addresses where the app
shows a page. React Router decides that in the browser, and the server
is Ruby, so `lib/app_pages.rb` matches the way React Router 8 does:
upper and lower case are the same, any number of slashes may end the
address, each part is percent-decoded before it is compared, and `:name`
and `?` mean what they mean in React Router.

A copy of someone else's rules can drift. So
`spec/lib/app_pages_contract_spec.rb` gives the same addresses to the
Ruby code and to React Router itself (through
`spec/support/app_pages_oracle.mjs`): every example, and 5,000 random
addresses built from the parts the patterns use. It fails on any
difference. A React Router upgrade that changes how it matches fails
that spec.

React Router's framework mode, with server rendering, would remove the
copy: the server matches the address with the same code the browser
uses, and answers 404 itself. That needs a Node server, which this app
does not have. Rails serves the app.

## The guards

Each of these fails before a deploy if a page is missing from the list,
or if the list and the code disagree:

- **ESLint** refuses `Route`, `Routes` and React Router's other ways to
  make a route anywhere except `app_routes.tsx`
  (`eslint.config.js`). So a new page cannot be added without the list.
- **`AppRoutes` throws** when the names in `routes.json` and the
  elements it is given differ
  (`tests/unit/components/app_routes.test.jsx`).
- **Every pattern needs an example**, and each example must open its own
  page in React Router (`tests/unit/routing.test.js`) and in the Ruby
  code (`spec/lib/app_pages_spec.rb`).
- **The integration suite** (real Rails) opens every example with a
  full page load and expects 200 and no "Page not found"
  (`tests/integration/pages.spec.js`). After every integration test,
  every address the app showed is asked of the server again and must
  answer 200 (`addressCheck` in `tests/helpers/test.js`). This is the
  check that finds a page the list does not have, because it does not
  read the list.
- **The release phase** runs `rake deploy:verify_app_pages` first
  (`Procfile`). A missing or broken `routes.json` fails the release, and
  the release before it keeps running.
- **`bin/deploy` and `bin/watch-deploy`** open every example on the
  deployed app and expect 200, and open
  `/.well-known/comeals-deploy-check` and expect 404. This shows that
  the rule works in production. It cannot find a page missing from the
  list, because the examples come from the list.

## What the server cannot know

The server knows the shape of an address, not whether its record
exists. `/meals/999999/edit` answers 200, and the app shows its own
"meal not found" screen. `/calendar/<anything>/<anything>` answers 200
too, and the app reads the type and date.

## To add a page

Add an entry to `routes.json` with its pattern and an example address,
and give `AppRoutes` an element of the same name in `index.jsx`. Nothing
else: the tests above open the example and compare the server with
React Router.

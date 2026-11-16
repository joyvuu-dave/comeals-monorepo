---
id: 34
title: Unknown paths answer with the app page
area: quality
status: done
opened: 2026-11-07
reviewed: 2026-11-16
watches:
  - app/controllers/fallback_controller.rb
  - app/frontend/src/routes.json
  - lib/app_pages.rb
  - config/routes.rb
---

# Unknown paths answer with the app page

## The challenge

A request for a path that does not exist gets a 404, at least where a program, not a person, is asking.

## The case that breaks it

A tool asks for a file under `/.well-known/` (a security contact file, an app link file, an agent manifest). It gets HTTP 200 and the app's HTML page, and reads that as the file. Lighthouse did this on 2026-11-07: its agent-manifest check failed with "Unexpected token '<'".

## Where we stand

- On the resident site, the server answers 404 with the plain `public/404.html` for every address that is not a page of the app. The pages are the entries of `app/frontend/src/routes.json` (`lib/app_pages.rb`, `config/routes.rb`). `spec/requests/unknown_paths_spec.rb` shows `/.well-known/security.txt`, `/foo.json` and other addresses get 404, and the pages get 200.
- The API and the admin site answer as before: an unknown address there was already a 404 (`spec/requests/unknown_paths_spec.rb`).
- Not deployed. Production still answers 200 for an unknown address until the next deploy.

## Options

1. A failing spec: `GET /.well-known/anything` answers 404. Then a route that answers 404 for every `/.well-known/` path the app does not serve.
2. The same for paths that end in a file extension (`.json`, `.txt`, `.xml`) and are not real files.

## Outside facts

- Heroku's router answers `/.well-known/acme-challenge/*` itself, with a 301 to its certificate service, and the request never reaches the app. Other `/.well-known/` addresses reach the app. So the 404 rule cannot stop Heroku from renewing the certificate. (checked 2026-11-16: `curl -sI https://comeals.com/.well-known/acme-challenge/x` answered 301 to va-acm.heroku.com with no `x-request-id`, which the app adds to every answer; `/.well-known/other-x` answered 200 with one)

## Decision

The server answers 404 for every address on the resident site that is not one of the app's pages, and the app and the server read one list of pages. The full decision, why the server copies React Router's rules, and the guards that stop a page from being left out: [ADR 0016](../adr/0016-one-list-of-pages-and-404-for-the-rest.md).

## History

- 2026-11-07: Opened, from a Lighthouse run on production.
- 2026-11-16: The owner decided, after a hostile review: the server answers 404 for every address that is not one of the app's pages (on the resident site; the API and admin do not change), and the app's login route becomes exactly `/`, `/reset-password` and `/confirm-email`. Old addresses from 2017–2018 are not kept. A 404 sends the plain 404 page, so a page missing from the list is seen at once. One list of pages, read by both the app and the server, with guards so a missed page fails a check before a deploy.
- 2026-11-16: Built: the list, the 404 rule, the guards, and the checks in `bin/deploy` and `bin/watch-deploy` (ADR 0016). Status done.
- 2026-11-16: The owner decided to remove the two API addresses of the old reset link (`/api/v1/residents/name/:token` and `/api/v1/residents/password-reset/:token`). They now get the API's usual 404.

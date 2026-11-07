---
id: 34
title: Unknown paths answer with the app page
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - app/controllers/fallback_controller.rb
---

# Unknown paths answer with the app page

## The challenge

A request for a path that does not exist gets a 404, at least where a program, not a person, is asking.

## The case that breaks it

A tool asks for a file under `/.well-known/` (a security contact file, an app link file, an agent manifest). It gets HTTP 200 and the app's HTML page, and reads that as the file. Lighthouse did this on 2026-11-07: its agent-manifest check failed with "Unexpected token '<'".

## Where we stand

- `https://comeals.com/.well-known/nonexistent-check` answered 200 with `text/html` on 2026-11-07.
- `FallbackController` serves the app page for every path the router does not know, so the browser app can show its own pages (`app/controllers/fallback_controller.rb`).
- Not a proven bug: there is no failing spec, and nothing the community uses is known to break.

## Options

1. A failing spec: `GET /.well-known/anything` answers 404. Then a route that answers 404 for every `/.well-known/` path the app does not serve.
2. The same for paths that end in a file extension (`.json`, `.txt`, `.xml`) and are not real files.

## History

- 2026-11-07: Opened, from a Lighthouse run on production.

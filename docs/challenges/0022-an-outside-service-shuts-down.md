---
id: 22
title: An outside service shuts down
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# An outside service shuts down

## The challenge

When any outside service the app uses closes, changes its price, or changes its API, there is a written plan to replace it.

## The case that breaks it

Pusher announces it will shut down in 90 days. Nobody has written down which parts of the app use it or what would replace it, so the work starts from nothing, under a deadline.

## Where we stand

The services the app uses, from AGENTS.md:

| Service                 | Used for                                  |
| ----------------------- | ----------------------------------------- |
| Heroku                  | Web and worker dynos, PostgreSQL, backups |
| Pusher                  | Live updates on screens                   |
| Gmail (SMTP)            | Password reset and email-change mail      |
| Bugsnag                 | Error reports                             |
| Skylight                | Performance                               |
| Better Stack            | Uptime checks and the status page         |
| healthchecks.io         | Alerts when a scheduled job does not run  |
| DNSimple                | DNS                                       |
| GitHub                  | Code, CI, issues, releases                |
| SolarWinds (Papertrail) | Logs                                      |

No replacement plan is written for any of them.

## Options

1. One line per service in this file: what breaks without it, what would replace it, and how long the change would take.
2. For the ones the app cannot run without (Heroku, PostgreSQL, Gmail), keep the app able to move with a normal deploy, and try it once.

## History

- 2026-11-07: Opened.

# Challenges

This folder lists hard things someone could ask this app to handle. For each one it says what would break, what the app does today, the options, and what was decided. The goal: the app keeps giving right answers while everything around it changes, and when it cannot, someone finds out before a person is hurt.

A challenge is not a decision and not a task:

| Kind of doc                    | Where it lives     | What it holds                                                                                     |
| ------------------------------ | ------------------ | ------------------------------------------------------------------------------------------------- |
| Challenge                      | `docs/challenges/` | A question, the case that breaks it, what we know, the options                                    |
| Decision                       | `docs/adr/`        | What was decided and why. A decided challenge links to its ADR.                                   |
| How to do a task               | `docs/runbooks/`   | Steps                                                                                             |
| Bug or work someone will start | GitHub issues      | A bug proven by a failing spec, or a piece of work. The challenge names the issue in its History. |

## How to read this folder

Start with the index at the bottom. Each challenge is one file, and each file can be read alone, with no other file open. Every file has the same parts in the same order, so a person or a program can find the same thing in each one.

**Front matter** (the lines between `---` at the top):

- `id`: the number. It never changes, and a number is never used twice.
- `title`: the challenge in a few words. The first heading repeats it.
- `area`: one of security, concurrency, portability, time, money, people, operations, proof, quality.
- `status`: one of these.
  - `open`: nobody is working on it.
  - `exploring`: someone is writing a design, a model or a test to learn more.
  - `planned`: we decided to do it. "Decision" says what.
  - `done`: built. "Decision" names the commit or ADR.
  - `declined`: we decided not to. "Decision" says why.
- `opened`: the day the file was written.
- `reviewed`: the last day someone read the whole file and fixed what was wrong. Where the file says "today", it means this day.
- `watches`: the files this doc describes. When one of them changes, the check fails until someone reads the doc again (see below).

**Sections**, in this order:

1. `The challenge`: what someone could ask of the app.
2. `The case that breaks it`: one real scenario, step by step.
3. `Where we stand`: what the app does as of the reviewed date. Each claim names the file, spec or command that shows it, or says "not checked".
4. `Options`: the ways to meet the challenge, with their costs.
5. `Outside facts` (when there are any): facts about other software, companies or laws. Each line ends with `(checked YYYY-MM-DD: source)`. A source of "Claude's memory" means nobody has read the real source yet. Read it before acting on the fact.
6. `Decision` (needed when the status is planned, done or declined).
7. `History`: one line per event, oldest first, each starting `- YYYY-MM-DD:`. The first line is the day it was opened.

## How these docs go wrong, and what catches it

A doc that was right when written becomes wrong in a few ways. Some are caught by `bin/challenges check`, which RSpec runs (`spec/bin/challenge_docs_spec.rb`), so `bin/check` and CI fail. The rest are rules for people and agents.

| How a doc goes wrong                                                                 | What catches it                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The code it describes changes                                                        | **Checked.** `docs/challenges/watched.txt` holds a fingerprint (SHA-256) of every watched file. When a watched file changes, the check fails and names the challenge. Read what the doc says about that file, fix it, then run `bin/challenges reviewed <id>`. |
| A file it names is moved or deleted                                                  | **Checked.** Every repo path written in backticks, and every relative link, must exist. To name a file that does not exist yet, write it without backticks and say it is not written yet.                                                                      |
| The outside world changes                                                            | **Checked.** An outside fact checked more than 365 days ago fails the check. Read the source again and change the date.                                                                                                                                        |
| The index no longer matches the files                                                | **Checked.** The index is written by `bin/challenges index`, and the check fails when it is out of date.                                                                                                                                                       |
| Words that stop being true by themselves ("currently", "recently", "soon")           | **Checked.** These words fail the check. Write the date or the plain fact. The same check refuses the words the project's plain-language rules ban.                                                                                                            |
| A file is missing a part, or has parts out of order                                  | **Checked.** Front matter keys, statuses, areas, dates, section names and order, History lines.                                                                                                                                                                |
| The status is wrong (the work is done, but the doc says open)                        | **Rule.** The commit that does the work changes the status and adds a History line in the same commit.                                                                                                                                                         |
| A decision is made in chat and never written down                                    | **Rule.** When the owner decides something about a challenge, write it in that challenge's History before the session ends.                                                                                                                                    |
| A claim nobody checked (often written by an LLM)                                     | **Rule.** Each claim in "Where we stand" names what shows it, or says "not checked". Before telling anyone a claim is true, check it again.                                                                                                                    |
| The challenge and its ADR disagree                                                   | **Rule.** Once decided, the ADR holds the decision. The challenge keeps one or two sentences and a link.                                                                                                                                                       |
| A watched file changes so often that people mark the doc reviewed without reading it | **Rule.** Watch the narrowest file that holds the fact. The commit that runs `bin/challenges reviewed` says in its message what was checked.                                                                                                                   |

The checks catch a doc that is out of date with the code, the files, or the calendar. They cannot catch a doc that was wrong on the day it was written. The rules are what stops that.

## Commands

```
bin/challenges check              check every rule above
bin/challenges index              write the index table below
bin/challenges reviewed ID [ID]   mark challenges as read again today, and record their watched files
bin/challenges new AREA TITLE     start a new challenge from the template, with the next id
```

## Index

<!-- The index below is written by bin/challenges index. Do not edit it by hand. -->

| #   | Challenge                                                                                              | Area        | Status | Reviewed   |
| --- | ------------------------------------------------------------------------------------------------------ | ----------- | ------ | ---------- |
| 1   | [An email change can take over an account](0001-email-change-account-takeover.md)                      | security    | open   | 2026-11-07 |
| 2   | [Keep every guarantee with no database locks we take ourselves](0002-no-explicit-database-locks.md)    | concurrency | open   | 2026-11-07 |
| 3   | [The same guarantees on every database Rails supports](0003-any-database-rails-supports.md)            | portability | open   | 2026-11-07 |
| 4   | [Many people changing many things at once](0004-many-people-many-changes-at-once.md)                   | concurrency | open   | 2026-11-07 |
| 5   | [Time zone rules change](0005-time-zone-rules-change.md)                                               | time        | open   | 2026-11-07 |
| 6   | [Dates far in the future](0006-dates-far-in-the-future.md)                                             | time        | open   | 2026-11-07 |
| 7   | [Pricing rules that change over time](0007-rules-that-change-over-time.md)                             | money       | open   | 2026-11-07 |
| 8   | [Birthdays on February 29](0008-february-29-birthdays.md)                                              | time        | done   | 2026-11-07 |
| 9   | [Inflation and the limit on one bill](0009-inflation-and-the-bill-limit.md)                            | money       | open   | 2026-11-07 |
| 10  | [A currency other than the US dollar](0010-a-second-currency.md)                                       | money       | open   | 2026-11-07 |
| 11  | [The same answer after every deploy](0011-same-answer-after-every-deploy.md)                           | money       | open   | 2026-11-07 |
| 12  | [Two residents with the same name](0012-two-residents-with-the-same-name.md)                           | people      | open   | 2026-11-07 |
| 13  | [Names that look the same but are different text](0013-names-that-look-the-same.md)                    | people      | open   | 2026-11-07 |
| 14  | [A resident leaves or dies with a balance](0014-a-resident-leaves-with-a-balance.md)                   | people      | open   | 2026-11-07 |
| 15  | [A family shares one email address](0015-a-family-shares-one-email.md)                                 | people      | open   | 2026-11-07 |
| 16  | [A former resident asks to be deleted](0016-the-right-to-be-deleted.md)                                | people      | open   | 2026-11-07 |
| 17  | [A gem or npm package is taken over](0017-a-package-is-taken-over.md)                                  | security    | open   | 2026-11-07 |
| 18  | [Password hashing gets weaker over time](0018-password-hashing-gets-old.md)                            | security    | open   | 2026-11-07 |
| 19  | [A stolen superuser account](0019-a-stolen-admin-account.md)                                           | security    | open   | 2026-11-07 |
| 20  | [The cryptography has to change](0020-cryptography-has-to-change.md)                                   | security    | open   | 2026-11-07 |
| 21  | [The domain or its certificate expires](0021-the-domain-or-certificate-expires.md)                     | operations  | open   | 2026-11-07 |
| 22  | [An outside service shuts down](0022-an-outside-service-shuts-down.md)                                 | operations  | open   | 2026-11-07 |
| 23  | [Someone else has to take over](0023-someone-else-takes-over.md)                                       | operations  | open   | 2026-11-07 |
| 24  | [No internet at dinner time](0024-no-internet-at-dinner.md)                                            | operations  | open   | 2026-11-07 |
| 25  | [Build the app again in 20 years](0025-build-it-again-in-20-years.md)                                  | operations  | open   | 2026-11-07 |
| 26  | [Backups that can be restored and read](0026-backups-that-can-be-restored.md)                          | operations  | open   | 2026-11-07 |
| 27  | [Prove the money math](0027-prove-the-money-math.md)                                                   | proof       | open   | 2026-11-07 |
| 28  | [Model the concurrency rules](0028-model-the-concurrency-rules.md)                                     | proof       | open   | 2026-11-07 |
| 29  | [A test catches every code change](0029-every-mutant-is-caught.md)                                     | proof       | open   | 2026-11-07 |
| 30  | [Tests that break the network, the database and the clock](0030-tests-that-break-things-on-purpose.md) | proof       | open   | 2026-11-07 |
| 31  | [Replay any failure exactly](0031-replay-any-failure-exactly.md)                                       | proof       | open   | 2026-11-07 |
| 32  | [Everyone can use it](0032-everyone-can-use-it.md)                                                     | quality     | open   | 2026-11-07 |
| 33  | [Deploys with no downtime](0033-deploys-with-no-downtime.md)                                           | operations  | open   | 2026-11-07 |
| 34  | [Unknown paths answer with the app page](0034-unknown-paths-answer-with-the-app.md)                    | quality     | open   | 2026-11-07 |
| 35  | [Measure the pages people use](0035-measure-the-signed-in-pages.md)                                    | quality     | open   | 2026-11-07 |

<!-- End of the index. -->

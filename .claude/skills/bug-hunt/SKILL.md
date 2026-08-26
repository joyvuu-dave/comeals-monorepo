---
name: bug-hunt
description: Look for subtle bugs on purpose, one seam at a time, and prove each one with a failing spec. Use when the user says "bug hunt", "find a subtle bug", "audit for bugs", or after a batch of merges.
---

# Bug hunt

This is the method that found #76 (a cache nobody cleared) and #77, and
the eight-year-old wrong `meals.start_time`. The method matters more
than effort. Vague "look for bugs" prompts find nothing; a list of named
seams, each checked to a done condition, does.

## Rules

1. **Work in a worktree.** `bin/agent-worktree bug-hunt-<date>` from the
   main checkout. Never edit the main checkout.
2. **A finding is a red spec.** Nothing is reported as a bug until a spec
   fails against `main` for that reason. Write the spec first, run it,
   paste its output in the report. A hunch is not a finding.
3. **Do not fix in the same run.** Report the spec and the proposed fix.
   The human decides. The spec stays red on the branch.
4. **Say "found nothing" plainly.** A hunt with no findings is a good
   result. Do not report weak findings to fill the page.
5. **Read the action table too.** `docs/agents/action-table.md` lists
   every action by entry point; its EMPTY and THIN cells are where the
   next seam bug is most likely. A hunt that finds a bug in a cell the
   table calls covered must fix the cell.
6. **Read the log first.** `docs/agents/bug-hunts.md` says which hunts ran
   and when. Pick the hunt that has not run for longest, or one the
   recent merges touched. Add a dated entry when done, even for
   "found nothing".
7. **A fix that changes what a rule sentence claims changes the
   sentence in the same commit.** CLAUDE.md and the ADRs state rules as
   facts ("admin has no zone wrapper", "refuses self-demotion"); a fix
   that makes such a fact false leaves a sentence the next invariant hunt
   has to catch. Two of them were caught on 2026-08-26, both from fixes
   made the same day. Grep the docs for the words the fix touches before
   committing it.
8. **Flag the incidental.** Anything wrong that is not a bug (a false
   sentence in CLAUDE.md, a stale comment, a column nothing reads) goes
   in the report under "Also noticed", with a file and line.

## The hunts

Each hunt names what to list, how to check every item, and when it is
done. Run one or two per session, all the way through. Half a hunt
proves nothing.

### Invariant hunt

List every sentence in `CLAUDE.md` and `docs/adr/*.md` that says
"never", "always", "must", "only", or "exactly". For each one:

- name the code that enforces it (a constraint, a trigger, a model
  guard, a controller check);
- name one path that skips that code: `update_all`, `delete_all`,
  `insert_all`, ActiveAdmin, a rake task, a seed, raw SQL, a callback
  that a `dependent:` cascade runs before;
- check whether the invariant still holds on that path.

Done when every sentence has a row with enforcer, skipping path, and
verdict.

### Cache hunt

`grep -rn "Rails.cache" app lib`. For each `fetch` or `read`:

- write down every column of every table whose value appears in the
  cached data;
- for each such column, find every write path (model callback, admin,
  rake, settlement, trigger) and check that it clears this cache;
- check the expiry: how long does a lie live if a clear is missed?

Done when each cache has a full table of columns and clearing writes.
`#76` and `#77` were both a row missing from that table.

### Time hunt

`grep -rnE "Time\.now|Date\.today|to_datetime|\.hours|\.days|Time\.zone|
beginning_of_day|end_of_day|utc" app lib`. For each hit:

- which zone is the value in — community, UTC, or the server's?
- if a `Date` becomes an instant here, does it go through the
  community zone (`Community#dinner_start_at` or
  `ActiveSupport::TimeZone[community.timezone]`)?
- is there a spec on a DST-switch day (2026-03-08, 2026-11-01)?

Also list every timestamp column that is compared to a date column.
Done when every hit has a zone written next to it.

### Lock hunt

List every write to `bills`, `meal_residents`, `guests`, and `meals`
in `app/` and `lib/`. For each, check that it runs inside
`with_meal_lock` or is refused by the settled-child trigger. Then list
every write in ActiveAdmin and every rake task, and check the same.
Done when every write is either locked, refused, or explained.

### Money hunt

For `MealLedger`, `Settlement`, `allocate_to_cents`, and
`billing:recalculate`:

- write a spec for each edge from CLAUDE.md that has no spec yet: zero
  attendees, one attendee, only children, only guests, zero cost,
  capped meal, multi-cook, a cook who also eats, a bill over $9,999.99
  in a sum;
- check that rounded balances sum to exactly zero for a randomized
  meal set (a property spec with 100 random ledgers);
- check every `Float` in the money path: `grep -rn "to_f\|Float" app`.

Done when every edge has a spec and the property spec passes.

### Dead column hunt

For every column in `db/structure.sql`, grep `app/` and `lib/` for its
name. A column nothing reads is a column nobody would notice being
wrong. For each dead column, check its writer: is the value correct?
`meals.start_time` was dead and wrong for eight years. Done when every
dead column is listed with a verdict: drop it, or it is right.

### Frontend seam hunt

For every API response the SPA keeps in state: what refreshes it? Pusher
event, poll, page reload, nothing? For each "nothing", name a write on
the server that changes that data and check what the screen shows
afterwards. Done when every piece of client state has a refresh path
written down.

## Report

End with:

- **Findings**: for each, the issue (file, line, scenario), the red spec
  path, the spec output, the proposed fix.
- **Also noticed**: wrong comments, false docs, dead code.
- **Hunts run**: which, and "found nothing" where true.
- The branch name and how to see the diff.

Then add the entry to `docs/agents/bug-hunts.md`.

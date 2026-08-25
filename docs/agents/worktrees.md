# Parallel agents and worktrees

Several Claude sessions can work on this repo at the same time. Each one
works in its own git worktree, so they never see each other's edits. This
doc is the full rulebook; the short version lives in CLAUDE.md.

## The model

1. **The main checkout (`comeals-monorepo`) belongs to the human.** An
   agent asked to change code starts with `bin/agent-worktree <task-name>`
   and works in the worktree it creates: `../comeals-<task-name>`, on
   branch `agent/<task-name>`, made from `main`.
2. **Every shared resource is either namespaced per worktree or guarded
   by a check that stops with a clear message.** Files are isolated by
   the worktree itself. Services are handled one by one — see the table.
3. **The result of a task is a branch, a report, and a question.** The
   agent merges and pushes only after the human reads the report and
   says yes.

## Shared resources

| Resource                    | Handling                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Files                       | Isolated by the worktree. Nothing to do.                                                                                                                                                                                                                                                                                                                                                                                                     |
| Test database               | **Namespaced.** The worktree's `.env` sets `TEST_DB_SUFFIX`; `config/database.yml` appends it, so tests there use `comeals_test_<task_name>`. RSpec, rake, and `bin/check` all read it through dotenv. Parallel test runs are safe.                                                                                                                                                                                                          |
| Dev server, ports 3000/3036 | **Guarded.** `bin/dev` kills a leftover server only if it was started from the same directory. A server from another worktree gets a message: leave it alone, work from tests.                                                                                                                                                                                                                                                               |
| Test-server ports           | **Namespaced** (#65). The worktree's `.env` sets `TEST_PORT_INTEGRATION`, `TEST_PORT_E2E`, and `TEST_PORT_ADMIN_E2E` — one block of three from 21000–21999, picked by a hash of the task name and checked against sibling worktrees' `.env` files. `bin/test-integration`, both Playwright configs (`tests/helpers/ports.js`), and `tests/admin/server.sh` all read them. The main checkout and CI set none of them and keep 3001/3037/3038. |
| Development database        | **Policy.** Worktrees never migrate or write `comeals_development`. New migrations run against the worktree's test database only (`RAILS_ENV=test rails db:migrate`). `bin/check` knows: in a worktree its migration check looks at the test database.                                                                                                                                                                                       |
| Admin e2e database          | **Namespaced.** `tests/admin/server.sh` appends `TEST_DB_SUFFIX`, so a worktree's admin suite uses `comeals_admin_e2e_<task_name>`. (It used to share one database, serialized by the fixed port 3038; per-worktree ports removed that serialization, so the database is namespaced like the test database.)                                                                                                                                 |

So: every suite — linters, RSpec, Vitest, and the browser suites — runs
in any number of worktrees at once. The port guards stay as the last
defense (`bin/test-integration` refuses a taken port,
`reuseExistingServer: false` fails loudly), but with each worktree on
its own block they should fire only when something is truly wrong: a
leftover server from a crashed run, or two checkouts sharing one `.env`.

## What an agent does when a guard fires

Do not kill the other session's processes. Run what still runs — RSpec,
Vitest, the linters — and say in the final report which suites could not
run and why, and which port was taken. The human decides what holds the
port and what runs next.

## If tests fail on code you did not touch

Another worktree's changes cannot be in your worktree. The failure comes
from your branch's base or from your own edits. Rebase on `main`, rerun,
and only then investigate. Never "fix" someone else's code to make your
suite pass — if a rebase brings in a real conflict with your work, report
it.

## Finishing a task

1. Rebase on `main`. If the rebase conflicts in shared files
   (`Gemfile.lock`, `db/structure.sql`, factories, shared CSS), stop and
   report the conflict instead of resolving it silently.
2. Run `bin/check` in the worktree. Commit.
3. Report, in this order:
   - what changed and why, in a few sentences;
   - the branch name (`agent/<task-name>`) and which suites could not
     run;
   - how to view the diff (`git diff main..agent/<task-name>` from the
     main checkout);
   - how to try the change locally, if there is something to try;
   - then ask: "Say **merge it** and I'll merge to main, push, and clean
     up."
4. Wait. Do not merge or push without the human's explicit yes in this
   conversation. A yes given for one branch covers only that branch.

On that yes, the agent runs, from the main checkout:

```bash
bin/agent-merge <task-name>
```

That one script does the whole landing: fast-forward merge into `main`,
push to GitHub, `bin/rails db:migrate` if the branch added migrations
(the migration is on `main` at that point, so this is the same act as
the human running it), `bin/agent-worktree-done` (removes the worktree,
drops its test and admin-e2e databases), and delete the branch. Pushing goes to GitHub
only; deploys always go through `bin/deploy`, run by the human.

The script refuses, with a message saying what to do instead, whenever
landing could lose or hide work:

- the main checkout is dirty, or not on `main`;
- `main` has local commits that origin does not — they may be unpushed
  on purpose, and `git push` would push them too;
- the branch is not a fast-forward of `main` — rebase it in its
  worktree, rerun `bin/check` there, and rerun the script.

One thing to expect after a merge that ran a migration: `git status` in
the main checkout may show a small diff in `db/structure.sql`. Look at
it. If it is only whitespace inside function bodies, it is not a real
change: the development database was built from squished SQL heredocs,
so `pg_dump` prints its functions on one line, while the committed file
comes from the test database. Restore it with
`git checkout db/structure.sql`. If the diff is anything else, stop and
report it.

It never rewrites history and never force-pushes. If local `main` is
only behind origin, it fast-forwards it first; that can only add commits
already on GitHub.

`bin/agent-worktree-done` (which the script calls, and which can also be
run alone for an abandoned task) refuses while the worktree has
uncommitted changes, and it always keeps the branch.

For the agent to run `bin/agent-merge` itself, the command must be
allowed in the Claude Code permission settings (for example
`"Bash(bin/agent-merge *)"` in `.claude/settings.local.json`). Allowing
this one script is deliberately narrower than allowing `git merge` and
`git push` in general: the script can only land a fast-forward of an
`agent/` branch, and the human's spoken "merge it" stays the gate.

## Why this exists

Telling an agent "another agent is working over there, ignore it" does
not work. The agent sees files and a failing test suite, not intent, and
it will edit the other agent's code to make the suite pass. Isolation by
worktree removes the shared state instead of asking the model to ignore
it. The guards exist for the state that worktrees cannot split — ports
and the shared databases — and they fail with a sentence that tells the
agent what happened and what to do, which agents follow far more reliably
than a raw "address already in use" error.

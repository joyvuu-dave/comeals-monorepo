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
3. **The result of a task is a branch, not a merge.** The human merges.

## Shared resources

| Resource                                 | Handling                                                                                                                                                                                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Files                                    | Isolated by the worktree. Nothing to do.                                                                                                                                                                                                               |
| Test database                            | **Namespaced.** The worktree's `.env` sets `TEST_DB_SUFFIX`; `config/database.yml` appends it, so tests there use `comeals_test_<task_name>`. RSpec, rake, and `bin/check` all read it through dotenv. Parallel test runs are safe.                    |
| Dev server, ports 3000/3036              | **Guarded.** `bin/dev` kills a leftover server only if it was started from the same directory. A server from another worktree gets a message: leave it alone, work from tests.                                                                         |
| Integration suite, port 3001             | **Guarded.** `bin/test-integration` refuses if the port is taken. One worktree at a time.                                                                                                                                                              |
| Playwright suites, ports 3037/3038       | **Guarded.** `reuseExistingServer: false`, so a collision fails loudly instead of silently testing another worktree's build. One worktree at a time.                                                                                                   |
| Development database                     | **Policy.** Worktrees never migrate or write `comeals_development`. New migrations run against the worktree's test database only (`RAILS_ENV=test rails db:prepare`). `bin/check` knows: in a worktree its migration check looks at the test database. |
| Admin e2e database (`comeals_admin_e2e`) | Serialized by the port 3038 guard, so it needs no suffix.                                                                                                                                                                                              |

So: linters, RSpec, and Vitest run in any number of worktrees at once.
The browser suites (Playwright e2e, admin e2e, integration) run in one
worktree at a time; a second one fails with a port message, not with
wrong results.

## What an agent does when a guard fires

Do not kill the other session's processes. Run what still runs — RSpec,
Vitest, the linters — and say in the final report which suites could not
run and why. The human decides the order of server-holding work.

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
2. Run `bin/check` in the worktree.
3. Report the branch name (`agent/<task-name>`) and what could not run.
4. Do not merge to `main`. Do not push.

The human then merges, runs migrations against the development database
if the branch added any, and cleans up:

```bash
git merge agent/<task-name>
bin/agent-worktree-done <task-name>   # removes worktree, drops its test DB
git branch -d agent/<task-name>
```

`bin/agent-worktree-done` refuses while the worktree has uncommitted
changes, and it always keeps the branch.

## Why this exists

Telling an agent "another agent is working over there, ignore it" does
not work. The agent sees files and a failing test suite, not intent, and
it will edit the other agent's code to make the suite pass. Isolation by
worktree removes the shared state instead of asking the model to ignore
it. The guards exist for the state that worktrees cannot split — ports
and the shared databases — and they fail with a sentence that tells the
agent what happened and what to do, which agents follow far more reliably
than a raw "address already in use" error.

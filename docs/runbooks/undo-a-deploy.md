# Runbook: undoing a deploy

Written 2026-10-15 for #133. Use it when production must go back to the
release before a deploy.

## First: did the deploy run a migration?

Rolling back only the code puts the old code on the database the new
code left. That is safe only when no migration ran in between, because
the old code may not run on what a migration made. The deploy after
v613 is the clearest case: it drops columns v613 writes, makes every meal
need a rotation, adds checks the old forms break, and marks dinners
cancelled, which v613 does not know about.

`bin/rollback-check <commit to go back to> <commit running now>` lists
the migrations in between. The Rollback workflow runs it for you and
refuses a code-only rollback when it finds any, unless you give it a
backup to restore first (below) or tick its `code_only_is_safe` input.
`code_only_is_safe` rolls back only the code even though migrations ran:
nothing is restored and nothing is lost. Tick it only after you have read
each migration the check lists and know the old code runs on what it
made, for example an index, or a table the old code never reads. The
Deploy workflow's automatic rollback runs the same check. When it finds
a migration, it leaves production as it is and fails the run.

## No migration: roll back the code

Run the **Rollback** workflow on GitHub (Actions, Rollback, Run workflow)
with a one-line reason. Leave `release` empty for the release before the
current one. It rolls back, runs the smoke test, pauses the daily deploy
(`DEPLOY_HOLD`), marks the release note, and files an issue to fix main.

## A migration ran: restore the backup, or fix forward

Two choices. Pick one before touching anything.

|              | Restore the backup and roll back                                                                         | Fix forward                                     |
| ------------ | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| What it does | the database goes back to the backup taken just before the deploy, and the code to the release before it | fix main and deploy again; nothing goes back    |
| What is lost | every write after the backup: sign-ups, costs, guests, settlements, admin edits                          | nothing                                         |
| When         | only inside the watch window the deploy plan sets, the first hours after the deploy                      | after the window, or when most of the app works |

After the watch window, fix forward. A restore then would throw away a
day of sign-ups and costs that nobody can type in again from memory.

### Restore and roll back

1. Find the backup. `bin/deploy` captures one just before it pushes, and
   prints its id. To find it again:
   `heroku pg:backups -a comeals-monorepo`; it is the newest one made
   before the deploy began.
2. Run the **Rollback** workflow with:
   - `reason`: one line;
   - `release`: the release production ran before the deploy (for the
     deploy after v613, `v614`, which runs v613's code). Empty means the
     release before the current one, which still runs the new code if a
     config var was set after the deploy. If the release runs the same
     commit as production runs now, the workflow stops before it turns
     maintenance on or restores anything, and says so;
   - `backup`: the id from step 1.

   It turns maintenance mode on, captures a backup of the database as it
   is, scales web to 0, waits until no web dyno runs, restores the backup
   from step 1, and rolls back the code. It waits for the rollback's
   release phase to succeed, scales web back to the number of web dynos
   it had, waits until they are up, turns maintenance off, and runs the
   smoke test. Then it does the same bookkeeping as a code-only rollback.
   While maintenance is on, Heroku answers every web request with the
   maintenance page, so nobody can write through a page or the API.

   Web goes to 0 because maintenance mode does not stop the background
   jobs. Solid Queue runs inside the web dyno (`SOLID_QUEUE_IN_PUMA`),
   and the web dyno keeps running under maintenance mode. With web at 0,
   no job of the new code runs on the restored database (#179). The
   maintenance page still shows with no web dyno. Heroku Scheduler jobs
   run in one-off dynos, not in the web dyno, so web at 0 does not stop
   them; if one is due in the next few minutes, wait until it ends.

3. If the deploy deleted Heroku Scheduler entries, add them back. The
   schedule moves to Solid Queue at the deploy after v613
   (`docs/runbooks/scheduler-cutover.md`); its entries are deleted a day
   later (step 6 there), so inside the watch window they are still
   there. The one that goes at the deploy itself is
   `rake residents:set_multiplier`: add it back (daily), and run it one
   time right away, as that runbook says.
4. Tell the community what was lost. The backup the workflow captured
   just before the restore holds every write made after the deploy:
   restore it into a local database (`heroku pg:backups:download`, then
   `pg_restore`) and list the `audits` rows created after the deploy
   began, so the sign-ups and costs can be typed in again.

### If it stops half way

The workflow's last step before the smoke test, "Say what to do by
hand", prints which state it left and the commands to run. It never
starts web again by itself.

- Maintenance is still on: production shows the maintenance page. That
  is the safe state; nobody can write.
- Web is at 0 (`heroku ps -a comeals-monorepo` lists no web dyno): no
  job runs. Leave it at 0 until the old code runs, because the new
  code's jobs would run on the restored database. Start it with
  `heroku ps:scale web=1 -a comeals-monorepo` as the last step before
  maintenance goes off.
- The restore failed: check that a backup of the database as it was got
  captured (`heroku pg:backups -a comeals-monorepo`), capture one if not,
  then run by hand, in this order:
  `heroku ps:scale web=0 -a comeals-monorepo`,
  `heroku pg:backups:restore <id> DATABASE_URL -a comeals-monorepo --confirm comeals-monorepo`,
  `heroku rollback <release> -a comeals-monorepo`, wait until
  `heroku releases -a comeals-monorepo` shows that release as succeeded,
  then `heroku ps:scale web=1 -a comeals-monorepo`,
  `heroku maintenance:off -a comeals-monorepo`, and
  `bin/smoke https://comeals.com`.
- The rollback failed after the restore: the old database is back under
  the new code, with web at 0. Run the rollback by hand, wait until its
  release succeeded, then scale web to 1 and turn maintenance off. A
  rollback runs the release phase of the old code
  (`bin/rake db:migrate`); if that is what failed,
  `heroku releases:output -a comeals-monorepo` shows why.
- Web is up but maintenance is still on: the old code runs on the
  restored database. Turn maintenance off and run the smoke test.

## Practise it on staging

`bin/staging-rehearsal` does not practise the undo. It only deploys the
new code to staging on a copy of production. Practise the undo by hand,
before the real deploy:

1. Restore a fresh production backup into staging, and push the code
   production runs now to staging. Staging then looks like production.
2. Capture a staging backup. This is "the backup before the deploy".
3. Push the new code to staging. Its release phase runs the migrations.
4. Run the Rollback workflow with `app: comeals-staging`, the staging
   release that ran the old code, and the backup from step 2.
5. Check that the smoke test passed on the old code, then scale staging
   to 0.

On staging the workflow only rolls back and smokes; it leaves
`DEPLOY_HOLD`, the release notes and the issues alone.

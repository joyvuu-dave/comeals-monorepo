# Runbook: undoing a deploy

Written 2026-10-15 for #133. Use it when production must go back to the
release before a deploy.

## When bin/deploy stops because the ledger check failed

After the balance refresh, `bin/deploy` runs `rake ledger:verify`, which
checks every settled balance against its source data. When it fails,
the deploy stops and prints the Rollback workflow command to run, with
the release before the deploy and the backup it took:

- After a maintenance deploy (a migration ran), maintenance stays on and
  web and the worker stay at 0, so nobody can use the site. The command
  has the backup in it: the workflow restores it, rolls back the code,
  and turns maintenance off. Do not scale web up first.
- After a push deploy (no migration), the new code serves. The command
  rolls back only the code. It also prints the backup id, for when the
  data must go back too; a restore loses every write since.

First look at the admin Ledger Checks page. If the nightly check failed
before the deploy too, the deploy did not cause it, and rolling back
will not fix it.

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
current one. It rolls back, runs the smoke test, pauses the weekly deploy
(`DEPLOY_HOLD`), marks the release note, and files an issue to fix main.

The worker dyno follows the release it goes back to. When that release
has a worker process type, the worker runs its code after the rollback.
When it has none (a release from before the worker dyno), the workflow
scales the worker to 0 before the rollback and says so: that code runs
no Solid Queue, and the new code's jobs must not run beside it. The
Deploy workflow's automatic rollback does the same.

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
   prints its id. Its whole output is also saved in
   `tmp/deploy/deploy-<time>-<app>.log`. To find it again:
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

   First, before it changes anything, it checks the backup (#248), and
   refuses it, with production left as it was, in any of these cases:
   - The backup id is not a plain id of this app's backups: `b` and a
     number for one taken by hand (as `bin/deploy` does), `a` and a
     number for a scheduled one. An id like `comeals-staging::b042` or
     an address would restore another database's data.
   - The backup is behind the release. The release's
     `db/production_schema_version.txt` names the newest of the
     migrations that were deleted from `db/migrate/` after production
     ran them. The rollback runs that release's `db:migrate`, which
     cannot run a migration that has no file. A release from before the
     file was added still holds every migration file, so this case does
     not apply to it.
   - The backup is newer than the release: it has a migration newer than
     both the release's version file and every migration file the
     release has. The old code would then run on a schema made by newer
     code, which is what the rollback is meant to undo. The backup
     `bin/deploy` takes before it pushes passes this, because it is
     taken before the new release's migrations run.
   - The backup has run no migration: it is not a copy of production's
     database.
   - The release has no version file and no migration file, so nothing
     tells which database its code needs.

   To read the backup's migrations, the workflow streams the backup into
   `pg_restore` and keeps only the `schema_migrations` rows; nothing of
   the backup is written to disk, and its signed address is masked in
   the log.

   Then it turns maintenance mode on, captures a backup of the database as it
   is, scales web and the worker to 0, waits until neither runs and no
   Solid Queue process is left (below), restores the backup from step 1, and rolls back the code. It waits for the
   rollback's release phase to succeed, scales the worker to 1 when the
   release it went back to has a worker process type, scales web back to
   the number of web dynos it had (one when it had none, as after a
   maintenance deploy that stopped part way), waits until they are up, turns
   maintenance off, and runs the smoke test. Then it does the same bookkeeping as a code-only rollback.
   While maintenance is on, Heroku answers every web request with the
   maintenance page, so nobody can write through a page or the API.

   The worker goes to 0 because maintenance mode does not stop the
   background jobs: Solid Queue runs on the worker dyno, which keeps
   running under maintenance mode. With it at 0, no job of the new code
   runs on the restored database (#179). `heroku ps` alone does not show
   that the worker stopped: on staging it once listed no worker while a
   worker process that Heroku had restarted still ran Solid Queue for 2
   more minutes (#245). So the restore also waits until no row of
   `solid_queue_processes` has a heartbeat from the last 75 seconds
   (Solid Queue writes one every 60 seconds). A process that stops
   cleanly deletes its row, so this wait is usually over at once. Both
   waits give up after 3 minutes, and then nothing is restored. A
   release from before the
   worker dyno has no worker process type; the workflow then stops the
   worker before the rollback, leaves it at 0, and says so. The
   maintenance page still shows with no web dyno. Heroku Scheduler jobs
   run in one-off dynos, so neither scale stops them; if one is due in
   the next few minutes, wait until it ends.

3. If the deploy deleted Heroku Scheduler entries, add them back. The
   schedule moves to Solid Queue at the deploy after v613
   (`docs/runbooks/scheduler-cutover.md`); its entries are deleted a day
   later (step 5 there), so inside the watch window they are still
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
starts web or the worker again by itself.

- "Check the backup" failed: the workflow changed nothing, so production
  is as it was before the run (after a maintenance deploy that stopped,
  that is maintenance on with web and the worker at 0). The step's
  message says why it failed. When the backup is behind the
  release, run the workflow again with a newer backup. When it is newer
  than the release, use the backup `bin/deploy` took before the deploy
  (its output names it), or a newer release.
  When the backup could not be read (the PostgreSQL 18 client did not
  install, or heroku or the download failed), run the workflow again.
  The workflow has no input to skip this check, because a backup nobody
  checked could be the kind this check is there to refuse. If it keeps
  failing, read the backup's newest migration by hand, on a computer
  with `pg_restore` 18 or newer. This streams the backup and prints one
  version; it writes nothing of the backup to disk:

  ```bash
  url=$(heroku pg:backups:url <id> -a comeals-monorepo)
  curl -sf "$url" | pg_restore --data-only --schema=public \
    --table=schema_migrations -f - | grep -E '^[0-9]{14}$' | sort -n | tail -n 1
  unset url
  ```

  Restore by hand (the steps under "The restore failed" below) only when
  it is not older than
  `git show <commit of the release>:db/production_schema_version.txt`,
  and not newer than both that and the newest file in
  `git ls-tree --name-only <commit of the release>:db/migrate`.

- Maintenance is still on: production shows the maintenance page. That
  is the safe state; nobody can write.
- Web and the worker are at 0 (`heroku ps -a comeals-monorepo` lists no
  web or worker dyno): no job runs. Leave them at 0 until the old code
  runs, because the new code's jobs would run on the restored database.
  Then start the worker with `heroku ps:scale worker=1 -a comeals-monorepo`
  only when that release has a worker process type (the step prints
  which), and start web with `heroku ps:scale web=1 -a comeals-monorepo`
  as the last step before maintenance goes off.
- The restore failed: check that a backup of the database as it was got
  captured (`heroku pg:backups -a comeals-monorepo`), capture one if not,
  then run by hand, in this order:
  `heroku ps:scale web=0 -a comeals-monorepo`, and
  `heroku ps:scale worker=0 -a comeals-monorepo` when `heroku ps` lists a
  worker. Wait until `heroku ps -a comeals-monorepo` lists no web or
  worker dyno and this prints 0 (no Solid Queue process sent a heartbeat
  in the last 75 seconds):
  `heroku pg:psql -a comeals-monorepo -c "SELECT count(*) FROM solid_queue_processes WHERE last_heartbeat_at > (now() AT TIME ZONE 'UTC') - interval '75 seconds'"`.
  An error that the table does not exist means no Solid Queue process
  runs. Then
  `heroku pg:backups:restore <id> DATABASE_URL -a comeals-monorepo --confirm comeals-monorepo`,
  `heroku rollback <release> -a comeals-monorepo`, wait until
  `heroku releases -a comeals-monorepo` shows that release as succeeded,
  then `heroku ps:scale web=1 -a comeals-monorepo`,
  `heroku maintenance:off -a comeals-monorepo`, and
  `bin/smoke https://comeals.com`.
- The rollback failed after the restore: the old database is back under
  the new code, with web at 0. Run the rollback by hand, wait until its
  release succeeded, then scale web to 1 and turn maintenance off. Web
  and the worker refuse to start on a database their code does not fit
  (`lib/schema_boot_check.rb`), so if one crashes at start,
  `heroku logs -a comeals-monorepo` says why; `heroku run` still works. A
  rollback runs the release phase of the old code
  (`bin/rake db:migrate`); if that is what failed,
  `heroku releases:output -a comeals-monorepo` shows why.
- Web is up but maintenance is still on: the old code runs on the
  restored database. Turn maintenance off and run the smoke test.

## The smoke test's sign-ins

The smoke test (`bin/smoke`) signs in on production as the owner's own
resident account, and as the owner's own admin account, when it has
their credentials. It only reads: the calendar, a meal page, the admin
dashboard and the reconciliations list. Signing in to admin records the
sign-in on that admin (time, IP address, count); nothing else is
written. Without them it checks the public pages only, and `bin/deploy`
says which are missing.

- `bin/deploy` reads them from `.env`, only on production:
  `SMOKE_EMAIL`, `SMOKE_PASSWORD`, `SMOKE_ADMIN_EMAIL` and
  `SMOKE_ADMIN_PASSWORD`, or, when those lines are missing, the owner's
  `RESIDENT_EMAIL`, `RESIDENT_PASSWORD`, `ADMIN_EMAIL` and
  `ADMIN_PASSWORD`. A variable already set in the shell wins.
- The Deploy and Rollback workflows read the same four names from the
  secrets of the GitHub environment `production`, and give them to the
  smoke test of production only.

When one of these passwords changes, update `.env` and the secret. When
the site refuses a login, the smoke test skips the checks behind that
login, runs the rest, and ends with code 2 and "SMOKE LOGIN REFUSED",
with the names to check (the top of `bin/smoke` lists every exit code).
It is told apart from a broken site by what the site says: the resident
login's "Incorrect password" or "No resident with email", or the admin
login page's "Invalid email or password.". A refused login is not a pass,
but nothing rolls back for it:

- `bin/deploy` fails and says to check the credentials, not to roll back.
- The Deploy workflow's Watch production step goes on with the Solid
  Queue checks and the log watch, which still roll back a broken
  release, then fails. The release note stays a draft.
- The Rollback workflow's smoke step fails and says the rollback is done.
- `bin/staging-rehearsal` makes its own smoke resident, so there a
  refused login means logins or the seed are broken, and it stops.

If the credentials are right and the login is still refused, sign in by
hand. If that fails too, the site is broken.

## Deploying a commit again after a rollback

A rollback changes the release that runs. It does not change Heroku's
git repository: its main branch still holds the commit that was rolled
back. A push of that same commit then builds nothing and makes no
release, so `bin/deploy` refuses it before it changes anything (#242).

To run that code again, push a new commit to `main` and deploy it the
usual way. When the code does not need to change (say the rollback was
for bad data, and the data is now fixed), an empty commit is enough:

```bash
git commit --allow-empty -m "Deploy again after the rollback"
git push origin main
# wait for CI, then
bin/deploy
```

Do not roll back to the release built from that commit instead. It runs
the release phase, but none of the steps `bin/deploy` adds: no backup,
no maintenance mode while a migration runs, no cache clear, no balance
refresh, and no checks.

## Practise it on staging

`bin/staging-rehearsal` does not practise the undo. It only deploys the
new code to staging on a copy of production. Practise the deploy and the
undo together, before the real deploy, with the real `bin/deploy` and
the real Rollback workflow:

First check that staging cannot email anyone, because step 1 puts real
residents' email addresses on it. This must print a value:
`heroku config:get COMEALS_STAGING -a comeals-staging`. And this must
list none of the vars in `bin/lib/staging_forbidden_vars.sh`:
`heroku config -a comeals-staging`. (`bin/deploy` checks both again in
step 2.)

1. Make staging look like production: scale staging's web and worker to
   0, restore a fresh production backup into it, and push the commit
   production runs to it.

   ```bash
   heroku pg:backups:capture -a comeals-monorepo
   heroku ps:scale web=0 -a comeals-staging
   heroku ps:scale worker=0 -a comeals-staging  # fails, harmless, when staging has no worker
   # Wait until this lists no web or worker dyno, and until the heartbeat
   # query in "If it stops half way" prints 0 for -a comeals-staging.
   heroku ps -a comeals-staging
   heroku pg:backups:restore "$(heroku pg:backups:url -a comeals-monorepo)" \
     DATABASE_URL -a comeals-staging --confirm comeals-staging
   git push --force https://git.heroku.com/comeals-staging.git \
     "$(heroku config:get HEROKU_SLUG_COMMIT -a comeals-monorepo):refs/heads/main"
   heroku ps:scale web=1 -a comeals-staging
   ```

   Start only web. A release from before the worker dyno has no worker
   process type, and Heroku refuses to scale one.

   Write down the staging release this push made. It is the release to
   go back to. To list the releases: `heroku releases -a comeals-staging`.

2. Deploy the new code to staging, from `main`, the same way production
   will get it:

   ```bash
   DEPLOY_APP=comeals-staging bin/deploy
   ```

   It runs every step of a production deploy, in the same order, on
   staging: the CI check, the local checks, a staging backup (it prints
   the id: this is "the backup before the deploy"), maintenance mode when
   a migration changed (it goes off only once web is up on the new
   release), the push, the release phase, the cache clear and the
   balance refresh, the worker, the health check, the Solid Queue check
   and the smoke test. It pushes to staging's own git address,
   never to the `heroku` remote. It first refuses a staging app that
   could send mail: staging holds real residents' email addresses, and
   the deploy starts the worker.

3. Run the Rollback workflow with `app: comeals-staging`, the release
   from step 1, and the backup from step 2:

   ```bash
   gh workflow run rollback.yml --ref main -f app=comeals-staging \
     -f reason="Rehearsal of the undo" -f release=vNN -f backup=bNNN
   ```

4. Check that the smoke test passed on the old code, then scale staging
   to 0.

On staging the workflow runs the same rollback steps as on production,
including maintenance mode and the restore when it is given a backup. It
leaves `DEPLOY_HOLD`, the release notes and the issues alone
(`spec/bin/rollback_workflow_spec.rb` checks this).

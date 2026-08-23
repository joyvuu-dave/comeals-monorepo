# ADR 0004: Admin Authorization — Three Levels, Split at the Money Path

- **Status:** Accepted
- **Date:** 2026-07-28
- **Supersedes:** points 4 and 5 of ADR 0002

## Context

ADR 0002 settled the API's authorization model: authorize by authentication,
not by ownership. It left one real boundary in place — admin writes require a
superuser — and described the second admin tier as "can look but not touch."

That description was accurate but the implementation was half-built, and the
half that was missing had a hole in it. What we found on 2026-07-28:

**The superuser flag could not be set from anywhere in the app.**
`app/admin/admin_user.rb` never listed `:superuser` in `permit_params` and
never rendered it in the form. A superuser creating another superuser got an
account with the flag off. Promoting a plain admin returned success and
changed nothing, because strong parameters drop silently. Every superuser in
production was made from a console.

**The last superuser could delete their own account.** Destroy was allowed for
superusers with no guard. Verified by request spec before the fix: the count
went 1 to 0. A community in that state cannot recover from inside the app —
settling, ledger edits, and granting the flag are all superuser actions, so
nobody is left who can promote anybody. The only way back is a console on the
dyno, which for a community running its own copy means calling us.

**The read-only email token was safe by accident, not by construction.**
`ApplicationController#read_only_admin_token?` runs the request as
`AdminUser.find(READ_ONLY_ADMIN_ID)`, and CSRF checking is skipped for it. Its
read-only-ness came entirely from that account happening to be a plain admin.
Production has `READ_ONLY_ADMIN_ID=11` (`commonhouse@swansway.com`,
`superuser=false`), which is correct — but nothing enforced it. Changing one
Heroku config value would have turned every link in every reconciliation email
into a write-capable, CSRF-exempt superuser session.

**The plain-admin tier was too weak to use.** "Look but not touch" meant a
plain admin could not add a resident, fix a typo in a reservation, or create an
event. Production has five of them, with 2 to 6 sign-ins each, and none has
signed in since 2024. That is what a useless account looks like: people logged
in, found every button missing, and stopped.

## Decision

Three levels, with the line drawn at the money path rather than at read vs
write.

| Level               | Reads                     | Writes                       |
| ------------------- | ------------------------- | ---------------------------- |
| **read-only token** | an allowlist of resources | nothing                      |
| **admin**           | everything                | everything except the ledger |
| **superuser**       | everything                | everything                   |

### 1. The line is the money path, not read vs write

Bills, attendance, guests, meals, reconciliations and balances are the ledger.
Writing any of them changes what somebody owes or is owed, so it needs a
superuser. (`LEDGER_MODELS` in `app/models/superuser_adapter.rb` also lists
`MealCharge` and `LedgerCheckRun`, added later: a meal charge is a settled
amount, and a ledger check run is the record of checking one.) Residents, units, events, rotations and both kinds of reservation
are ordinary community admin, open to any admin.

This matches how a co-housing group actually divides labor: some committee
adds and retires residents, some other person or committee handles the money.
It also makes the second tier worth having, which "look but not touch" did not.

Two membership decisions are worth writing down because they are not obvious:

- **Meal is on the restricted list**, even though creating a meal is ordinary
  admin. Its `closed` and `max` fields and its nested guests all feed the cost
  split, and ActiveAdmin authorizes per resource, not per field. Erring the
  other way would put a money-changing field behind a non-money permission.
- **Resident is not on the restricted list**, even though residents carry a
  `multiplier` price category. Attendance snapshots its own multiplier into
  `meal_residents.multiplier` when the row is created, so editing a resident
  never reaches back into a settled meal. If that stops being true, this
  boundary has to move.

`Community` is restricted along with `AdminUser`: it holds `cap`, which
rescales every subsidized meal's settlement.

Creating a `Community` is a third case. The table holds exactly one row, and
that row is made once, on a fresh deployment with an empty database. So the
adapter refuses `new` and `create` on `Community` as soon as a row exists, for
a superuser too. The check sits in the adapter rather than in
`app/admin/community.rb` because ActiveAdmin asks the adapter the same question
to draw the "New Community" button and to run the action, so one rule hides the
button and denies the URL. The routes stay in place — they are how bootstrap
works. The model's `enforce_singleton` validation is still the last line.

### 2. The token path is read-only by construction

`SuperuserAdapter` refuses every write on a token request regardless of which
`AdminUser` the token resolves to. Read-only is now a property of the request,
not of the account. Pointing `READ_ONLY_ADMIN_ID` at a superuser no longer
widens the emailed links.

The adapter learns about the token through `Current.read_only_admin_token`,
set by a `before_action` in `ApplicationController`. This indirection exists
because ActiveAdmin constructs the authorization adapter with the resource and
the user and never the request, so the adapter has no other way to see it.

### 3. The token reads an allowlist, not the whole admin

A token request may read `Bill`, `Meal`, `Reconciliation`, `Resident` and
`Unit` — the resources the emails link to and what those pages link on to.

**This is not about privacy of the ledger.** Attendance and cook costs are
already on the community calendar, and a balance is derived from exactly that
data. A recipient who widens the filter to see everyone's balances is working
as intended; the `q[resident_id_eq]` in the mailer link is a convenience
filter, never a scope. The `common_house_collection_email` deliberately links
to the unfiltered balance list.

The allowlist exists for a narrower reason: a link mailed to the whole
community should not also be a way to enumerate admin email addresses and
sign-in activity, or resident birthdays. That is a different kind of
information that happened to sit behind the same read permission.

The Dashboard stays readable on the token path. ActiveAdmin redirects an
unauthorized request to the admin root, so refusing the Dashboard would turn
every denial into a redirect loop.

### 4. A community always keeps at least one superuser

Demoting or destroying the last superuser is refused at three layers:

- `AdminUser#refuse_demoting_last_superuser` and
  `#refuse_destroying_last_superuser`, both `prepend: true` for the same reason
  Meal and Reconciliation prepend theirs (issue #26) — dependent callbacks run
  first otherwise, and a swallowed inner rollback leaves partial writes.
- The `comeals_refuse_last_superuser_removal` trigger
  (`20260728120000`), which holds for paths that skip callbacks: `update_all`,
  `delete_all`, `update_column`, psql. "At least one row has `superuser` set"
  is a statement about the table, not a row, so no CHECK constraint or partial
  unique index can express it. A trigger is the only database-level way to say
  it.
- The admin controller additionally refuses **self-demotion** at any count.
  The model rule protects the community; this one protects the person. When
  other superusers remain, demoting yourself is recoverable, but it is still
  almost never what you meant to click.

The trigger takes `PERFORM ... FOR UPDATE` on the other superuser rows before
counting. Without the lock, two concurrent demotions each see the other as
still-superuser and both commit, leaving zero. If the two transactions are
demoting each other they deadlock and Postgres aborts one, which is a safe
failure: the outcome is one demotion, never both.

### 5. Hand-written admin actions must authorize themselves

ActiveAdmin authorizes inside `resource` and `build_resource`
(`ResourceController::DataAccess`), not in a `before_action`. An action that
loads its own records never consults the adapter at all.

`app/admin/meal_resident.rb` — the attendance-correction path from issue #25 —
did exactly that: `Meal.find(params[:meal_id])` and `meal.meal_residents.new`,
so no authorization ran. **This was already true before this ADR**, and it was
live in production: any signed-in admin, superuser or not, could add or remove
attendance on a closed meal. Nothing surfaced it because the plain-admin tier
had no working buttons anywhere else, so nobody exercised the difference.

It now calls `authorize!(action_name.to_sym, MealResident)` in a
`before_action`. Authorizing against the class rather than a built row is
deliberate: the decision is per resource, and building the row first would run
model callbacks before deciding whether the actor may write at all.

The other custom controller actions are safe too (checked 2026-08-23). The
custom `destroy` in `unit.rb`, `meal.rb`, `resident.rb` and `rotation.rb` calls
`destroy!`, which goes through `resource`. The `send_password_reset` member
action in `resident.rb` loads the row through `resource`. The hand-written
`index` and the `schedule_preview` collection action in `community.rb` load
nothing through ActiveAdmin, so each calls `authorize!` itself.

The rule for anything added later: **if an admin action does not call
`resource` or `build_resource`, it is unauthorized until it calls `authorize!`
itself.**

### 6. Refusing beats silently dropping

Setting `superuser` without the right to do it is refused with a flash message,
not dropped by strong parameters. A silent drop looks like success, which is
how the flag came to be unmanageable in the first place.

## Consequences

- Plain admins become useful. The five dormant production accounts can now do
  the work they were presumably created for, without gaining ledger access.
- Every existing production superuser keeps exactly what they had.
- The token links keep working unchanged. What changes is that they can no
  longer be widened by config, and no longer reach the admin list.
- `Current` gains request state that authorization depends on. Anything that
  runs admin authorization outside a request — a console, a job — sees
  `Current.read_only_admin_token` as nil, which falls through to the ordinary
  signed-in rules. That is the right default, but it means the token rule is
  only enforced where the `before_action` runs.
- Adding a new ActiveAdmin resource now requires a decision: is it on the money
  path? Forgetting leaves it open to plain admins. `LEDGER_MODELS` is where a
  money-path resource goes, `GOVERNANCE_MODELS` is where a "decides who may
  act" one goes, and `SUPERUSER_ONLY_MODELS` is the two of them joined.
  `spec/models/superuser_adapter_spec.rb` iterates that list, so a new
  restricted model is covered automatically once added.

## What is pinned

- `spec/models/superuser_adapter_spec.rb` — the adapter logic, including that
  a token request writes nothing even when its account is a superuser, and
  that an unidentifiable subject fails closed.
- `spec/requests/admin/superuser_authorization_spec.rb` — the money-path split
  end to end through routing.
- `spec/requests/admin/superuser_management_spec.rb` — granting, promoting,
  demoting, self-demotion, and the last-superuser guard through the UI.
- `spec/requests/admin/read_only_token_spec.rb` — the token path: what it
  reads, what it cannot reach, what it cannot write.
- `spec/models/admin_user_spec.rb` — the model guards and the database
  trigger, including `update_all` and `delete_all`.
- `spec/requests/admin/attendance_correction_spec.rb` — that the hand-written
  attendance actions refuse a plain admin, which is what proves the
  `authorize!` call in `meal_resident.rb` is wired.

## Not addressed here

The token is shared, has no expiry, and can only be revoked by rotating
`READ_ONLY_ADMIN_TOKEN`. It travels as a query parameter, so it leaks through
referrer headers and server logs, and a forwarded email grants standing access
to whoever receives it. Fixing this properly means per-resident signed links
with an expiry, which is its own piece of work. It is a real limit, and it is
the thing to fix first if this code goes to a community that does not know
each other as well.

## Alternatives considered

- **Collapse to one tier and delete the plain-admin level.** Rejected once we
  found the token depends on it. It would also have handed write access to
  anyone holding a mailed link.
- **A third human role (owner / treasurer / admin).** Rejected as more
  structure than a co-housing group needs. Three capability _levels_ turned out
  to be necessary, but only two of them are kinds of people; the third is the
  token identity.
- **Per-field authorization instead of per-resource.** Rejected: ActiveAdmin
  authorizes per resource, and hand-rolling field-level checks across Meal and
  Community would be more moving parts than restricting those two resources.
- **A CHECK constraint or partial unique index for the last-superuser rule.**
  Not possible; the invariant is about the table, not a row.

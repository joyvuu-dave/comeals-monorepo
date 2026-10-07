# Comeals API

Comeals is a meal sign-up and cost-splitting app for one cohousing
community. Residents sign up for shared dinners, volunteer to cook, and
the cost of each meal is split among the people who ate. This page
describes the JSON API the app uses. It is the same API for a script or
an agent.

Base URL: `https://comeals.com/api/v1`. Every path below is relative to
that. Requests and responses are JSON unless the endpoint says otherwise.

Source code: https://github.com/joyvuu-dave/comeals-monorepo. The routes
are in `config/routes.rb`; the handlers are in `app/controllers/api/v1/`.
Every endpoint has request specs in `spec/requests/api/v1/`.

## Sign in

Sign in with a resident's email and password. You get back a token.

```
POST /residents/token
{ "email": "ann@example.com", "password": "secret" }
```

Response:

```
{ "token": "<jwt>", "community_id": 1, "resident_id": 12,
  "username": "Ann", "timezone": "America/Los_Angeles" }
```

Send the token on every later request in the `Authorization` header:

```
Authorization: Bearer <jwt>
```

`?token=<jwt>` in the query string also works, but the header is the
normal way.

The token is a JWT. It does not expire on its own. It stops working when
the resident changes their password. There is nothing to refresh.

Only residents with an email can sign in. Children have no email and no
login.

A wrong email or password returns `400` with a `message`. A request that
needs a login and has none, or has a bad token, returns `401`.

Other sign-in endpoints:

| Method   | Path                               | What it does                                                                                                                  |
| -------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `GET`    | `/residents/id`                    | Returns the signed-in resident's id as a bare number. A cheap way to check that a token still works.                          |
| `DELETE` | `/sessions/current`                | Signs out. For a JWT this only tells the client to forget the token; the token itself stays valid until the password changes. |
| `POST`   | `/residents/password-reset`        | Body `{ "email": ... }`. Emails a reset link. No login needed.                                                                |
| `GET`    | `/residents/name/:token`           | Returns `{ "name": ... }` for a reset token that is less than 24 hours old. No login needed.                                  |
| `POST`   | `/residents/password-reset/:token` | Body `{ "password": ... }`. Sets the new password. No login needed.                                                           |

## Rate limits

Per IP address:

- `POST /residents/token`: 20 per 5 minutes.
- `POST /residents/password-reset`: 10 per hour.
- Everything under `/api/`: 600 per minute.

Over the limit you get `429` with a `Retry-After` header (seconds) and a
`message`.

## Errors

Every error the API answers on purpose is JSON with one `message`
string:

```
{ "message": "Meal has been closed." }
```

A `500` from an error the API did not expect has no `message`. Rails
answers it with its HTML error page, or with
`{ "status": 500, "error": "Internal Server Error" }` when the request
accepts only JSON. An error from Heroku's router, in front of the app,
is an HTML page too.

| Status | Meaning                                                                                                                                              |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `400`  | The request was understood but refused. The `message` says why. Bad input, a rule of the meal (closed, full, reconciled), or a wrong id in the body. |
| `401`  | No token or a bad token.                                                                                                                             |
| `404`  | The record in the URL does not exist.                                                                                                                |
| `409`  | Two writes to the same meal collided. Nothing was saved. Send the same request again.                                                                |
| `429`  | Rate limit.                                                                                                                                          |

Note that `404` is only for the record named in the URL path. A wrong id
in the body (say, an unknown `resident_id` in a bill) is a `400`.

## Ids in the URL are mostly ignored

There is exactly one community, and the API does not check the
`community_id` in paths like `/communities/:id/calendar/:date`. Any
number works. The `:id` in `/residents/:id/ical` does matter; that
endpoint returns one resident's feed.

## Dates and times

- A meal has one `date` (no time), written `YYYY-MM-DD`.
- `start` and `end` query parameters are `YYYY-MM-DD` dates, and both
  ends are included.
- Times in responses are in the community's time zone when the request
  carries a token, and in UTC otherwise.
- Events and common house reservations take their start and end as
  separate parts (see those sections), not as one timestamp.

## Two shapes of meal data

There are two ways to read a meal, and they return different things:

- `GET /meals/:meal_id/cooks` returns the **meal form**: who is signed
  up, who is cooking, the bills, and the meal's state. This is the
  endpoint to use when you want to know or change anything about a meal.
- The calendar endpoint returns **calendar cards**: a title string, a
  start, an end, a color, and a URL. They exist to draw the month view. They do not carry ids you can
  write with (the `id` field is a cache key like `meals/42-2026...`, not
  the record id).

The record id is the number in the card's `url` field (`/meals/42/edit`
→ meal 42) and in the `next_id` / `prev_id` fields of the meal form.

## Meals

### Find a meal

| Method | Path                      | Returns                                                                                                                   |
| ------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/meals/next`             | `{ "meal_id": 42 }` for the next meal on or after today. `400` with `{ "meal_id": null }` if there is none.               |
| `GET`  | `/meals/:meal_id/history` | `{ "date": ..., "items": [...] }`. Each item is one change to the meal: `id`, `user_name`, `description`, `display_time`. |

### Read the meal form

```
GET /meals/:meal_id/cooks
```

```
{
  "id": 42,
  "date": "2026-08-25",
  "description": "Tacos",
  "closed": false,
  "closed_at": null,
  "max": null,
  "reconciled": false,
  "next_id": 43,
  "prev_id": 41,
  "bills": [
    { "resident_id": 7, "amount": "0.0", "no_cost": false }
  ],
  "residents": [
    { "id": 12, "meal_id": 42, "name": "3 - Ann", "short_name": "Ann",
      "attending": true, "attending_at": "2026-08-20T18:02:11.000-07:00",
      "late": false, "vegetarian": true, "can_cook": true, "active": true }
  ],
  "guests": [
    { "id": 9, "meal_id": 42, "resident_id": 12, "vegetarian": false,
      "created_at": "..." }
  ]
}
```

- `bills` lists the cooks. A cook is anyone with a bill row. `amount` is
  a decimal string in dollars. `no_cost: true` means the cook spent
  nothing, and that bill is skipped when the cost is split.
- `residents` lists every active resident, plus anyone no longer active
  who is signed up for this meal or has a bill on it. So every cook in
  `bills` is in `residents`. Each row has an `attending` flag. `name` is
  `"<unit> - <name>"`. A client should show a resident in its sign-up
  list only when `active` or `attending` is true, and should let a
  resident who is not `active` be chosen as a cook only for the bill they
  already have.
- `guests` lists guests. Each guest belongs to a resident, the host.
- `closed`, `max`, and `reconciled` are the meal's state. See "Rules"
  below.
- `next_id` and `prev_id` are the ids of the meals just after and just
  before this one, by date. They are never `null`. At the last meal,
  `next_id` is the meal's own `id`. At the first meal, `prev_id` is the
  meal's own `id`.

### Sign up and cancel

| Method   | Path                                                      | Body                                     | What it does                                                                                           |
| -------- | --------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `POST`   | `/meals/:meal_id/residents/:resident_id`                  | `{ "late": false, "vegetarian": false }` | Signs the resident up. If already signed up, updates `late` and `vegetarian` instead. Returns the row. |
| `PATCH`  | `/meals/:meal_id/residents/:resident_id`                  | `{ "late": ..., "vegetarian": ... }`     | Changes `late` or `vegetarian` for a signup.                                                           |
| `DELETE` | `/meals/:meal_id/residents/:resident_id`                  |                                          | Cancels the signup.                                                                                    |
| `POST`   | `/meals/:meal_id/residents/:resident_id/guests`           | `{ "vegetarian": false }`                | Adds one guest hosted by that resident. Returns the guest, including its `id`.                         |
| `DELETE` | `/meals/:meal_id/residents/:resident_id/guests/:guest_id` |                                          | Removes that guest.                                                                                    |

Any resident can sign up, cancel, or add guests for any other resident.
The app is a shared screen in the common house, and the API is the same.
The token only records who made the change in the history.

### Change the meal

| Method  | Path                          | Body                         | What it does                                                           |
| ------- | ----------------------------- | ---------------------------- | ---------------------------------------------------------------------- |
| `PATCH` | `/meals/:meal_id/description` | `{ "description": "Tacos" }` | Sets the menu text.                                                    |
| `PATCH` | `/meals/:meal_id/closed`      | `{ "closed": true }`         | Closes or reopens the meal.                                            |
| `PATCH` | `/meals/:meal_id/max`         | `{ "max": 30 }`              | Sets a cap on a closed meal. `null` removes it. `400` on an open meal. |
| `PATCH` | `/meals/:meal_id/bills`       | see below                    | Sets the cooks and their costs.                                        |

### Bills

```
PATCH /meals/:meal_id/bills
{ "bills": [
    { "resident_id": 7, "amount": "48.50", "no_cost": false },
    { "resident_id": 9, "amount": "0", "no_cost": true },
    { "resident_id": 11 }
] }
```

The list is the full set of cooks. A cook not in the list is removed. A
row with only `resident_id` keeps that cook and leaves their stored
amount alone. A row with `amount` or `no_cost` rewrites both.

Rules for `amount`:

- A string or number with at most two decimal places: `"48.50"`, `"48"`,
  `48.5`. Whole cents only; `"48.505"` is refused.
- From `0` to `9999.99`. Never negative.
- An empty or missing `amount` on a touched row means `0`.

The response is `200` with `message`, and `bills` as the server stored
them. One exception: adding a third cook to a future meal while another
meal in the same rotation still has fewer than two cooks returns `400`
with `"type": "warning"`. The bills are still saved; the `message` only
says the rotation is short of cooks.

## Rules an agent must know

These come from the database and the models, not the controller, so
every path enforces them. Each refusal is a `400` with a `message`.

1. **Reconciled meals cannot change.** Once a meal is in a settlement
   (`reconciled: true` in the meal form), every write to it, its
   signups, its guests, and its bills is refused:
   `"Change not permitted. Meal has already been reconciled."`. This is
   an accounting rule: the ledger is not edited, it is appended to.
2. **A closed meal's headcount is frozen.** While `closed` is true and
   `max` is null, no one can sign up, cancel, add a guest, or remove a
   guest (`"Meal has been closed."`). The cook closes a meal to know
   how much food to buy.
3. **`max` opens extra spots on a closed meal.** With `closed: true` and
   `max: 30`, signups are allowed while the headcount (signups plus
   guests) is below 30 (`"Meal has no open spots."` when full). A
   signup or guest added after the meal closed can be removed again.
   One added before the close cannot. `max` cannot be set below the
   current headcount, and cannot be set at all on an open meal.
4. **Bills are whole cents, 0 to 9999.99.** See "Bills".
5. **Writes to one meal take a lock on that meal.** If a settlement is
   running, or another write collides, you get `409`. Nothing was
   saved. Resend the same request.
6. **Every write is recorded.** `GET /meals/:meal_id/history` shows who
   changed what, by the resident whose token was used.

## How the cost is split

For a meal, the cost is the sum of the cooks' bills (skipping `no_cost`
bills). Each person who ate counts with a weight, called a multiplier: full
price is 2, half price is 1, free is 0. An adult and a guest are 2; a
child is 1 or 0 depending on age. Cost per unit is cost divided by the
sum of multipliers. Each eater is charged `unit cost × multiplier`; each cook is
credited what they spent. If the community has set a cap per
unit, the cost per unit stops at the cap and the community pays the
rest. All of this is computed at full precision and rounded to cents
only at settlement, and the rounded results always sum to zero. The
API does not expose balances; those are in the admin site.

## Calendar

```
GET /communities/:id/calendar/:date
```

`:date` is `YYYY-MM-DD`. Returns the six-week grid that holds that date's month: `id`, `month`,
`year`, and lists of calendar cards under `meals`, `bills`, `rotations`,
`birthdays`, `common_house_reservations`, `guest_room_reservations`, and
`events`. Every card has `id` (a cache key, not a record id), `type`,
`title`, `start`, `end`, and usually `url` and `color`. Bill cards mark
which days have a cook. An event or a common house reservation is in
every grid it overlaps, so one that starts before the first day shown
and ends inside the grid is in it. A birthday card is dated in the year
of the weeks shown, not this year, and names the age the person turns
that day. A person born after the last day shown has no card.

The response carries an `ETag`. Send it back as `If-None-Match` to get
`304` when nothing changed.

| Method | Path                                          | Returns                                                                                                                                                                                           |
| ------ | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/communities/:id/birthdays?start=YYYY-MM-DD` | Birthday cards for the month two weeks after `start` (the calendar's middle), dated in that month's year. Without `start`, this month. A `start` that is not a date returns `400 "Invalid date"`. |
| `GET`  | `/communities/:id/hosts`                      | Active adults as `[id, name, unit_name]` triples, sorted by unit. These are the residents who can host a guest or hold a reservation.                                                             |

## Cooking rotations

A rotation is a cooking schedule: a set of residents who share the
cooking for a run of meals.

| Method | Path             | Returns                                                                                                                                                                                                                                                   |
| ------ | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/rotations/:id` | `{ "id": <database id>, "place_value": <1 for the earliest rotation, 2 for the next, ...>, "description": ..., "residents": [ { "id", "display_name", "signed_up" } ] }`. `signed_up` is true for members who have a bill on one of the rotation's meals. |

## Settlement preview

```
GET /reconciliations/preview
```

Takes `?cutoff=YYYY-MM-DD`, a past day. Returns what a settlement at that
cutoff would claim and store, computed the same way a real settlement is
and written nowhere. Returns `cutoff_date`, `generated_at`, a `summary` (`meal_count`,
`total_cost`, `earliest_meal_date`, `latest_meal_date`,
`residents_affected`, `units_affected`), the `meals` it would claim (each
with its cost numbers, counts, and `cooks`), `balances` per resident and
per unit, and `warnings` about data that settles fine but usually means
someone forgot a step (`kind` is one of `bill_with_no_attendees`,
`attendance_without_bill`, `zero_bill_not_flagged`; show `title` and
`body` for a kind you do not know). An `attendance_without_bill` warning
names a meal that is not in `meals`: people ate, no cook billed, and a
settlement never claims a meal without a bill, so it is left behind until
someone enters one. Money is a string; the sign is the
direction: positive means the community owes the resident. No meals to
settle is a `200` with empty lists, not an error.

```
POST /reconciliations
{ "cutoff": "YYYY-MM-DD" }
```

Settles the period up to and including `cutoff`, a past day: the same
thing the nightly task does, with the day chosen by you. Claims the
meals the preview listed, writes the ledger, refreshes every resident's
running balance, and emails each cook. Returns `201` with `id`, `date`,
`cutoff_date`, and `meal_count`. Creating it is the lock: the settlement
and its meals are frozen from this moment and there is no undo, so
preview first. `400` when the cutoff is not a past day or there is
nothing to settle; `409` when another settlement or a meal write got
there first — nothing was saved, send the same request again.

## Bills as records

There is no endpoint that reads a bill on its own. To read or write a
bill's amount, use the meal form and `PATCH /meals/:meal_id/bills`.

## Events

An event is a note on the calendar with a title, a start, and either an
end or the `all_day` flag.

| Method   | Path                 | Returns                                                                                                           |
| -------- | -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `GET`    | `/events/:id`        | `id`, `title`, `description`, `start_date`, `end_date` (null when all day), `allday`, `created_at`, `updated_at`. |
| `POST`   | `/events`            | Creates. Body below.                                                                                              |
| `PATCH`  | `/events/:id/update` | Updates. Same body.                                                                                               |
| `DELETE` | `/events/:id/delete` | Deletes.                                                                                                          |

Create and update body:

```
{ "title": "Work party", "description": "Bring gloves",
  "all_day": false,
  "start_year": 2026, "start_month": 9, "start_day": 5,
  "start_hours": 9, "start_minutes": 0,
  "end_hours": 12, "end_minutes": 30 }
```

On update, a field left out of the body keeps its stored value.

An event is one day. With `"all_day": true` the hour fields are ignored.
Without `all_day` on create, it is false; on update, the stored value
stays. End must not be before start. When both times are empty (all
four hour and minute fields left out or `""`), a timed event runs from
midnight to midnight. When only one of the two times is empty, it
returns `400 "Pick both a start and an end time."`. Each part is a
whole number, as a number or a string of digits. A date that does not
exist (February 30), or on a timed event an hour or minute that is out
of range or not a whole number, or blank while the other half of its
time is given, returns `400 "Error: Invalid date"`. Days before 1582 are
counted in the Gregorian calendar too, so February 29, 1500 does not
exist. A start or end the database cannot store also returns that 400:
before midnight UTC on November 24, 4714 BC (`start_year` -4713, since
year 0 is 1 BC), or after the end of 294276 in UTC.

Times are read in the community's time zone. A time that the clock
skips when daylight saving time starts is read with the UTC offset from
before the skip: in America/Los_Angeles, 02:30 on 2026-03-08 is saved
as 03:30 PDT. So a start of 02:30 with an end of 03:00 that day returns
`400 "Start time must occur before end time"`. A time that the clock
shows twice when daylight saving time ends is the first of the two:
01:30 on 2026-11-01 is saved as 01:30 PDT (UTC-7). This is the rule in
RFC 5545, section 3.3.5, and it holds for every clock change since 1972.
Some earlier changes were not a one-hour skip or the end of daylight
saving time, and a time near one of those can be read another way: 12:05
on 1883-11-18 in Los Angeles happened twice, and it is saved as the
second one.

## Guest room reservations

One reservation per day. `resident_id` is the host.

| Method   | Path                                  | Returns                                             |
| -------- | ------------------------------------- | --------------------------------------------------- |
| `GET`    | `/guest-room-reservations/:id`        | `{ "event": { "id", "resident_id", "date" } }`.     |
| `POST`   | `/guest-room-reservations`            | Body `{ "resident_id": 12, "date": "2026-09-05" }`. |
| `PATCH`  | `/guest-room-reservations/:id/update` | Same body.                                          |
| `DELETE` | `/guest-room-reservations/:id/delete` | Deletes.                                            |

A day that is already taken returns `400`. So does a day the database
cannot store, with `"Date is not a date the database can store"`:
before November 24, 4714 BC (`-4713-11-24`, since year 0 is 1 BC),
after December 31, 5874897, or a day the Gregorian calendar does not
have, such as `1500-02-29`.

## Common house reservations

A block of time in the common house on one day. `resident_id` is who
booked it. `title` is optional.

| Method   | Path                                    | Returns                                                                    |
| -------- | --------------------------------------- | -------------------------------------------------------------------------- |
| `GET`    | `/common-house-reservations/:id`        | `{ "event": { "id", "resident_id", "title", "start_date", "end_date" } }`. |
| `POST`   | `/common-house-reservations`            | Body below.                                                                |
| `PATCH`  | `/common-house-reservations/:id/update` | Same body.                                                                 |
| `DELETE` | `/common-house-reservations/:id/delete` | Deletes.                                                                   |

Body:

```
{ "resident_id": 12, "title": "Book club",
  "start_year": 2026, "start_month": 9, "start_day": 5,
  "start_hours": 19, "start_minutes": 0,
  "end_hours": 21, "end_minutes": 0 }
```

The date and time parts follow the rules for timed events: both times
empty means midnight to midnight, one time empty returns
`400 "Pick both a start and an end time."`, and a date that does not
exist, a bad hour or minute, or a time the database cannot store,
returns `400 "Error: Invalid date"`. A time on a daylight saving night
is read the same way as for an event: 02:30 on 2026-03-08 is saved as
03:30 PDT, and 01:30 on 2026-11-01 is the first 01:30, in PDT. A block
that overlaps another returns `400 "Time period is already taken"`.

A block that ends when it starts is saved and returns 200, but it holds
no time. It overlaps only a block that starts before its time and ends
after it. Both times empty gives such a block at midnight. Only a
booking that runs past midnight can overlap it, and only admin can make
one. A start and an end that are the same, such as 14:00 to 14:00, give
such a block too, and so does 02:30 to 03:30 on 2026-03-08, which is
saved as 03:30 to 03:30. A booking from 03:00 to 03:30 that day can
still be made; one from 03:00 to 04:00 overlaps it.

## Calendar feeds (iCal)

Both return `text/calendar` and need no token. They are meant for a
calendar app's subscribe-by-URL feature.

| Method | Path                    | Returns                                                                                                           |
| ------ | ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/communities/:id/ical` | Every meal as a "Common Dinner" event.                                                                            |
| `GET`  | `/residents/:id/ical`   | That resident's meals: "Cook Common Dinner" on days they cook, "Attend Common Dinner" on days they are signed up. |

## Version

```
GET /version
```

`{ "version": 613, "commit": "<git sha>", "staging": false }`. No token
needed. `version` is the Heroku release number.

## What the API does not do

- No endpoint creates meals, residents, units, or rotations, and none
  reads balances or settlements. Those live in the admin site, which
  needs an admin login and is not an API.
- No endpoint lists residents on its own. The meal form and `/hosts`
  are the two lists.
- No endpoint lists meals, bills, rotations, events, or reservations by
  date range. The calendar endpoint is the one list, one month at a
  time.
- Nothing is paginated. The lists are small.

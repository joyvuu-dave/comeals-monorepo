# ADR 0009: A bills save names only the cooks it changes, with the bill the page saw

- **Status:** Accepted
- **Date:** 2026-10-07
- **Issue:** #135 (also #136 and #91)
- **Amended:** 2026-10-09: each cook row saves on its own (#150), and the
  third-cook warning is a `200`. See "What the meal page sends".

## Context

A bills save (`PATCH /api/v1/meals/:meal_id/bills`) used to send the full
list of cooks the page showed. The server removed the bill of any cook
the list left out, and made a $0 bill for a listed cook who had none.

That breaks when two pages have the same meal open. A adds Xavier as a
cook with $30, and the save answers 200. B's page has not loaded the
meal again yet: a live update is a job, then Pusher, then a GET, so it
takes up to about 5 seconds, and longer if B's phone slept. B types their
own cost. B's list does not have Xavier, so the server removes Xavier's
$30 bill. B sees "Form submitted." Nobody sees anything wrong, Xavier is
never paid back, and the people who ate pay $30 less. The second form of
the bug: A removes Xavier, and B's save brings him back with a $0 bill.

The meal lock (ADR 0003) makes the two saves run one after the other. It
does not check that B's list is still the meal's list. The same thing
happened with one page: a save for a meal the person had left, then a
save from that meal's rows loaded again before the first save was
answered. And it was the cause of #91: a cook the page did not show was
a cook the list left out, so the next save removed them.

While looking at this we also found that an amount sent as a JSON number
was read as a Float. Rails turns `25.499999999999999` into the Float
25.5, its text passes the whole-cents grammar, and $25.50 was stored,
instead of the sub-cent amount being refused (money rule 1).

## Decision

### A save is a list of edits

```
{ "edits": [
    { "op": "add",    "resident_id": 7, "to":   { "amount": "48.50", "no_cost": false } },
    { "op": "change", "resident_id": 9, "from": { "amount": "5.0",   "no_cost": false },
                                        "to":   { "amount": "7.00",  "no_cost": false } },
    { "op": "remove", "resident_id": 4, "from": { "amount": "0.0",   "no_cost": true } }
] }
```

Each edit names one cook. `from` is that cook's bill as the page saw it,
and `to` is the bill the person wants. An add has no `from` and a remove
has no `to`. `op` says which of the three it is. The sides alone would
tell, but naming the op makes a request easy to read and its errors
easy to word, and explicit beats implicit (CLAUDE.md). A cook the edits
do not name is never touched, so a page cannot remove a cook it never
saw.

Amounts are text, compared as numbers: `"5"`, `"5.0"` and `"5.00"` are
the same, and `""` is 0. A JSON number is refused with 400. `no_cost` is
`true` or `false`, or the text `"true"` or `"false"` in a form-encoded
body, and anything else is refused. (Amended 2026-10-08: `no_cost` now
follows the rule of every true/false value the API reads, `TrueOrFalse`
(#138). It also takes `1`, `0`, `"1"` and `"0"`, and a refusal says
"No cost must be true or false".)

### The rules under the meal lock

Under the meal lock, the server reads the stored bills once and looks at
each edit:

- the cook's bill already is `to`, or a remove finds no bill: the edit is
  done, and nothing is written;
- the bill is `from`, or an add finds no bill: the edit is written,
  through the models;
- anything else: the meal changed after the page read it.

One edit of the third kind refuses the whole save: nothing is written,
not even the edits that matched, and the answer is a `409` with
`"type": "stale"`, a message that names the cooks that changed, and the
bills as stored. All of this runs inside the block that RetryOnConflict
runs again after a conflict (ADR 0005), so a second try reads the bills
again and can answer stale.

A settled meal is checked before the edits, before the lock and again
under it, so it gets the settled words even when an edit is also stale:
sending the edit again could never work. The one check that comes before
it is the key of a save sent again (below).

The third-cook warning runs after the writes, inside the lock. It is
given the cooks before the save and reads the cooks after it from the
database, so it describes what the save did. The answer's bills are read
there too, so they are what this save left. The save was written, so the
answer is a `200` with `"type": "warning"` (amended 2026-10-09; it was a
`400`, which told a client that nothing was saved).

### Two kinds of 409, told apart by `type`

- No `type`: two writes collided, or the meal lock was not free in time.
  Nothing was written. Send the same request again.
- `"type": "stale"`: the bills changed since the page read them. Nothing
  was written. Read the meal again and build new edits.

`409` is the status for a request that cannot be applied to the
resource as it is now (RFC 9110, 15.5.10; RFC 5789, 2.2, for PATCH). The
idea is the one JSON Patch uses: its `test` operation checks a value
before anything is written, and the whole patch is applied or none of it.

### A body in the old format is refused

A body with a `bills` key gets `400` with `"type": "outdated"` and
"Nothing was saved, because this page is out of date. Please reload the
page and enter the costs again." Nothing is written. Each refusal writes
one line to the log, so the owner can see how often old pages still try.

### A resend after no answer, and the idempotency key

The done rule makes a resend safe in every case but one. If the first
try was written and its answer was lost, and someone then set the bill
back to the first try's `from` before the resend arrived, the resend
writes again and replaces their change, with no message.

To close that case every bills save carries an `Idempotency-Key` header,
by the IETF draft "The Idempotency-Key HTTP Header Field"
(draft-ietf-httpapi-idempotency-key-header-07). The page sends one new
key with each save, and the same key when it sends that save again.

- **The value** is a Structured Field String (RFC 9651): printable ASCII
  in double quotes, like `"8e03978e-40d5-43e8-bc93-6894a57f9324"`. The
  app adds one rule, 1 to 255 characters. Parameters after the string
  are checked against the grammar and dropped, because the draft defines
  none and RFC 9651 asks a field not to refuse one it does not know
  (`IdempotencyKeyHeader`).
- **The order of the checks.** First, a save whose body and key are
  right, and whose key the meal has a row for, gets the answer for a
  seen key (below). Then a settled meal gets the settled words, as for
  every write. Then a body in the old format gets `outdated`, with or
  without a key: a page that old sends no key, and "out of date" is what
  tells the person to reload. Then a missing or wrong key is a `400`.
  Then the edits are checked. Under the meal lock, in each try, the key
  is looked up again and then the settled check runs again, in the same
  order, before the stored bills are read.
- **Why the key comes before the settled check.** A key's row is written
  with its save's bills, under the meal lock, after the lock's own
  settled check passed. So a row means that save was written while the
  meal was open. If the answer to the first try was lost and the meal
  was settled before the page sent it again, the settled words would
  tell the person their costs were not saved, which is false. The
  look-up under the lock is needed too: Heroku's router answers 503
  after 30 seconds while the first try can still be running, so the page
  can send it again before the first try commits. The second try's
  look-up before the lock then finds no row, and a settlement can take
  the meal lock between the first try's commit and the second try.
- **The table.** `bills_save_keys` holds the meal id, the key, the
  SHA-256 of the edits, and the time, with a unique index on the meal id
  and the key. A row is written only for a save that was written, in the
  same transaction as its bills. A save refused with a `400` or a `409`
  keeps no key, and a try that is rolled back for a conflict takes its
  key with it, so the next try is not told it was already made.
- **A key the meal has a row for** is looked up before the lock and
  again under it, each time before the settled check, and under the lock
  before the stored bills are read. With the same edits, the answer is
  `200` with `"type": "replayed"` and the bills as stored now, and
  nothing is written. With other edits, the answer is `422`, and nothing
  is written. Both answers are the same on a settled meal.
- **"The same edits"** is a SHA-256 of what the edits ask for: each edit
  as its op, cook, `from` and `to`, with amounts written as numbers, in
  the order sent (`BillsPayload#fingerprint`). Not a hash of the bytes:
  a resend after a dropped connection comes with a new Pusher socket id,
  and that is still the same save.
- **Two saves with the same key at once.** The meal lock puts them one
  after the other. The second one's snapshot is taken by the lock it
  waits for, so it does not see the first one's key. PostgreSQL refuses
  it as a conflict instead, because the first save changed what the
  second read: at the lock, when the first save wrote a bill (a bill's
  write touches the meal row), or at the insert of the same key, when
  the first save wrote nothing. RetryOnConflict runs it again, and it
  finds the key. The unique index is the rule that holds even if the
  look-up were skipped.
- **Keys older than 7 days are deleted**, every hour, by a command in
  `config/recurring.yml` (`BillsSaveKey.delete_expired`), like Solid
  Queue's own `clear_finished_jobs`. Not inside a bills save, so a save
  writes only its own meal's bills and its own key.

Two choices differ from what the draft suggests. The draft asks the
server to answer a resend "with the result of the previously completed
operation". Keeping that answer would keep a copy of the bills as they
were, which is a stored money value (money rule 8). So the answer is the
bills as stored now, marked `replayed`, and a client must not read them
as what its first try wrote. And the draft suggests Problem Details
(RFC 9457) for the `400` and the `422`; this API answers every refusal
with a `message`, and these do too.

The table records requests, not money. The bills stay the source of
truth, and nothing reads an amount from it, so it is not a cache of
financial data (money rule 8).

### What the meal page sends

(Amended 2026-10-09 for #150. Before, the page sent one save at a time
for the whole cooks box: a save waited 500 ms after the last edit, and a
save asked for while another was on its way waited in a queue until that
one was answered. A save still waiting in the page was lost with no
message when the page reloaded or closed.)

- **Each cook row saves on its own.** A row's save is the difference
  between that row and its base (`app/frontend/src/helpers/bill_edits.ts`).
  It names at most two cooks: the cook at the row's base and the cook it
  shows. The same cook is a `change`; another cook is a `remove` of the
  cook at the base and an `add` of the cook shown. A bill whose cook no
  row shows (#91) is never named. Saves of different rows go at the same
  time: the server takes edits per cook, so it can take them in any
  order.
- **When a row saves.** 2 seconds after its last edit (a keystroke, a
  pick, the No cost switch), or at once when the person leaves its cost
  box or presses Enter in it. Leaving the cook menu does not save: a
  person who picks a cook and then goes to the cost box sends one save
  with both. Coming to the cost box starts the row's wait again, if it
  has one. On a phone, closing the menu, tapping the box and waiting
  for the keyboard can take about 2 seconds, and the pick's save would
  lock the row under the first digits typed. Leaving the meal sends every row that waits to save, at
  once, to the meal it was typed on (#107), and the next meal shows at
  once.
- **A base on each row.** Each row keeps a base: the cook and bill the
  server has for that row, as far as the page knows. It moves when the
  row's save is built, not when it is answered. A base is never moved
  back.
- **A row is read-only while its save is on its way.** Its cook menu,
  cost box and No cost switch take no edit until the save is answered,
  the other rows stay free, and a question open in the row closes. So a
  row never has a second save waiting behind its first, and when the
  answer comes the row still shows what the save sent. The controls keep
  their look and their focus (`readonly` on the cost box, `aria-disabled`
  on the menu and the switch), so the lock shows nothing for the first
  second. The cost box keeps its white background: the app gives every
  other read-only box a gray one. After one second a small spinner shows
  inside the row's cost box, which is `aria-busy`, with no words.
- **Two saves on their way never name one cook.** Saves for different
  cooks can reach the server in either order. Saves for one cook cannot:
  if a row's `add` of Bob arrived before another row's `remove` of Bob,
  the remove would undo it with no message. So a row cannot take a cook
  that another row is still changing: one that has the cook at its base
  but shows another, or whose save that names the cook is on its way.
  The cook menus do not offer that cook, and a pick of it does not land.
  The cook is offered again once that row's save is answered.
- **The answer changes no row.** The page checks it instead: each cook
  the save named must show what it sent. A difference is reported to
  Bugsnag as a server bug, except on a `replayed` answer, where someone
  may have saved since. Either way the meal loads again. A `200` with
  `"type": "warning"` shows "Cooks saved." and the warning, and names the
  meal when the person has left it.
- **A failure that may not be final is sent once more**, unchanged and
  with the same key: a `409` with no `type`, a `5xx`, or no answer. The
  row stays locked until that try is answered. The page stops waiting
  after 35 seconds, because Heroku's router ends a request at 30. The
  person sees the failure only if the second try fails too, and the
  second try alone decides what they see. For a meal they left, it is
  the message that names the meal. The meal on screen joins that message
  while it still shows. Otherwise, for the meal on screen, if the second
  try got no answer from the app (no answer, or a `5xx` page with no
  message from the app), the page says "Your cooks and costs may not
  have been saved. Check them when the meal shows again.", whatever the
  first try got. The second try may have been written, even after a
  first try that wrote nothing (a `409` with no `type`, or the app's
  `503`). If the second try got the app's own words (a `409` with no
  `type`, or the app's `503`), the page shows those words, even after a
  first try with no answer. Puma runs one thread, so the first try was
  finished before the second was read, and if it had been written, the
  second would have been answered as `replayed`. Either way the meal on
  screen loads again.
- **A final failure is not sent again:** a `stale` `409`, a `400` or a
  `422`. The person sees the server's words (or, for a meal they left,
  the message that names the meal, which the meal on screen also joins
  while it shows), and the meal on screen loads again as on its first
  load, frozen until it arrives, once nothing is pending for it. A `422`
  can only come from a bug in the page, so it is reported too.
- **The meal's rows are not built again while an edit is pending (#136):**
  a save of the meal on its way, a row in its wait before its save, or a
  row that differs from its base. The fetch waits until nothing is
  pending.
- **One cook picked in two rows** cannot be sent, because a cook has one
  bill. Neither row's save is sent, and the message names the cook. The
  cook menus do not offer a cook picked in another row, so only a bug in
  the page can get here.
- **Removing a cook that no other menu offers asks first.** A cook who
  was retired, or whose "can cook" was turned off, after cooking is
  offered only in their own row (#91). Picking another name there, or
  the blank, is a `remove` of their bill, and once the meal loads again
  only an admin can add it back. So that pick asks first, with the
  app's yes/no bar. Until the meal loads again, their row still offers
  them, so the person can undo the pick.
- **The blank clears the row's cost.** A row with no cook has no cost, so
  picking the blank clears the cost and the No cost switch too, and the
  next cook picked in the row does not take the last cook's cost.
  Picking another cook straight away keeps the cost with the row. The
  row keeps what the blank cleared, for the cook it cleared it from.
  The next time that cook is picked in the row, if the row shows no
  cost then, the cost and the switch come back. If the blank's save
  was already sent, the next save is an `add` with that cost. A cost
  typed for another cook after the blank is the row's own, and stays.
- **A reload the page makes itself waits.** Logout, Refresh in the "new
  version" banner, and Refresh on the error page first freeze the cook
  rows and send every row with an edit the server does not have. Then
  they wait until no bills save is on its way and no row waits to save,
  for at most 5 seconds. A reload ends every request on its way, and
  logout takes the token away. Moving to another meal or to the
  calendar does not wait.
  - If a save they waited for was not saved, or may not have been, or a
    row could not be sent (one cook in two rows), the page does not
    reload. Its message is on screen, and a reload would take it away
    before the person could read it. The rows take edits again, and the
    next tap goes on.
  - Otherwise the page reloads, and the rows stay frozen until it does.
  - The error page shows because something threw, and the store may be
    what broke. So if the wait itself throws, its Refresh reports the
    error and reloads anyway: it is the only way off that page.
- **A page that is hidden or closed sends what waits.** When the browser
  fires `visibilitychange` to hidden, or `pagehide`, every row that waits
  to save is sent at once with `fetch` and its `keepalive` flag, which
  lets the request finish after the page is gone. On a phone,
  `visibilitychange` to hidden is the last event a page can count on: a
  page in the background may be closed with no other event. The save
  carries its Idempotency-Key and the token, like any other, so
  `navigator.sendBeacon`, which can send neither, is not used. If the
  page stays open, the answer is handled as usual. The app listens for
  these events on every page, because a save for a meal the person left
  can still be on its way while the calendar shows.
- **A save on its way is sent again when the page closes.** A save goes
  by XMLHttpRequest, and the browser ends it with the page. So on
  `pagehide`, when the browser does not keep the page in its
  back-forward cache, each bills save on its way is sent again,
  unchanged, with `keepalive` and the same key. If the first try was
  written, the server answers the second as `replayed` and writes
  nothing more. A save that went with `keepalive` already is not sent
  again. The page does not read the answer, because it will be gone; if
  it stays open after all, the first try's answer is the one it reads.
  A reload the page makes itself does this before it starts: Logout and
  both Refresh buttons when their wait says the page may reload, and
  the reload after a page's code fails to load. WebKit, the engine of
  every browser on an iPhone, ends a request on its way as soon as a
  reload starts, before `pagehide`, and logout takes the token away
  before its reload. The token is read when a request is made, not in a
  later step (`axios_auth.js`), so logout can take it away right after.

## Consequences

- (2026-10-09, #150.) A cost typed on one row no longer waits for another
  row's save. A cost still in a row's wait is sent when the person
  leaves the meal, logs out, taps Refresh, or the page is hidden or
  closed, and a save on its way is sent again when the page reloads or
  closes. Two cases still lose it with no message: a page the browser ends without
  firing `visibilitychange` or `pagehide` (a crash), and a `keepalive`
  save the browser refuses or the network drops after the page is gone.
- (2026-10-09.) After the first tap, Logout and both Refresh buttons can
  now leave the person on the page: when a save they waited for was not
  saved, the page stays with the message, and the next tap goes on.
- (2026-10-09.) A client that read the third-cook warning as a failure
  must read it on its success path: the answer is a `200`.
- A save can no longer remove or bring back a cook it did not name. Both
  forms of #135 are fixed, and so is the cause of #91: a bill the page
  does not show is never named, so it is never removed.
- When two pages change the same cook's bill, the second gets a message
  instead of replacing the first page's value without one.
- A page loaded before this change gets the out-of-date answer on every
  bills save until it is reloaded. Sign-ups, guests, the menu and closing
  are not affected. The version banner offers "Refresh" within about 5
  minutes of a deploy.
- A rollback to v613 (2146821) answers a new page's `edits` body with a
  500 and writes nothing. v613's `update_bills` starts with
  `params[:bills].pluck`, which raises on a body with no `bills` key
  before any write, and v613 has no `rescue_from` for it. Its
  reconciled check runs before that, so a settled meal still gets the
  settled words. Bills saves from new pages fail until those pages are
  reloaded.
- The third-cook warning's reads of the rotation's other meals now run
  inside the SERIALIZABLE transaction. The transaction reads more rows,
  so it can conflict a little more often. A conflict is retried.
- Two bills saves that run at the same time can refuse each other, even
  when they are for different meals. Each one looks up its key in
  `bills_save_keys` and then adds one. At SERIALIZABLE, PostgreSQL
  refuses the second to commit when the first added a key where the
  second looked. While the table is small, PostgreSQL reads all of it to
  look up a key, so this happens to any two saves that overlap. When the
  table is larger, PostgreSQL reads the index instead, and this happens
  when the two meals' keys sit on the same page of the index, as
  tonight's meal and tomorrow's usually do. RetryOnConflict runs the
  refused save again.
  Production runs one Puma thread, so two saves do not run at the same
  time there today. Running more threads makes this happen. It also
  means a `409` or the app's `503` on a second try no longer proves the
  first try was not written, so the meal page's words after "no answer,
  then the app's words" could say nothing was saved when it was.
- The hourly delete and a bills save can refuse each other the same way
  while the table is small. The delete runs in the Solid Queue worker,
  not in a Puma thread, so this can happen with one Puma thread too. The
  delete is one short statement, so it nearly always commits first, and
  the save is refused and run again. If a save commits while the delete
  runs, the delete is the one refused, and `BillsSaveKey.delete_expired`
  runs it again, with the tries and waits RecurringJob gives a scheduled
  job.
- A client that sends amounts as JSON numbers is refused and must send
  text. The SPA always sent text.
- A client must send an `Idempotency-Key` with every bills save. A save
  without one is refused with `400`.
- A resend to a meal that was settled after the first try was written
  gets `replayed`, not the settled words, and nothing is written. Its
  key is looked up before the settled check, and the bills in the answer
  are the settled ones. A resend with other edits gets `422`. A new save
  to a settled meal, with a new key, still gets the settled words.
- A rollback to v613 ignores the header and leaves `bills_save_keys` in
  place. Nothing reads it there, and the hourly delete is not in v613's
  schedule, so the rows stay until this change is deployed again.

## Amended 2026-10-09: guest adds use the same key

A guest add whose answer was lost could also be written twice. The meal
page showed no guest after no answer, so the person tapped again, the
second tap added a second guest, and the host paid for two
(`tests/integration/meal-actions.spec.js`, "a guest add whose answer was
lost, tapped again, adds one guest"). So `POST
/meals/:meal_id/residents/:resident_id/guests` now takes the same
`Idempotency-Key` header, by the same rules:

- **The table** is its own, `guest_add_keys`: the meal, the key, the host
  and the `vegetarian` flag the add asked for, the guest it made, and the
  time. `bills_save_keys` does not fit, because a guest add's answer
  names the guest it made. When that guest is removed, the row stays and
  its `guest_id` becomes null, so the key still adds nothing.
- **The same key** with the same host and flag answers `200` with
  `"type": "replayed"` and the guest as stored now, or `null` once it was
  removed. With another host or flag, `422`. Both come before the
  settled check, before the lock and again under it, as for a bills save.
- **The meal page** sends a new key with each tap. When an add gets no
  answer from the app, the page keeps its key, and the next tap for the
  same host and flag sends it again. A `replayed` guest that the page did
  not show at that tap is the guest the tap asked for. If the page
  already showed it, or it was removed since, the tap was for one more
  guest, and the page sends a new add (`data_store_guest_adds.ts`).
  While a host's add waits for its answer, that host's add-guest control
  takes no taps. Without that, a second tap in the 35 seconds an add can
  wait sent a new key, so both adds could be written.
- **The guest shows once the server says yes, whatever loaded since.**
  A load of the meal can land while the add is out, from a read made
  before the guest was written. If it landed before the add's answer,
  the answer still shows the guest, with its seat, unless that load
  already had it. If it went out before the answer and lands after it,
  it is not used, and the meal loads again (#156). Either way, the
  person never sees the guest go away and taps again for a second one.
- **Keys older than 7 days are deleted** every hour, by
  `GuestAddKey.delete_expired` in `config/recurring.yml`.
- **A client must send the header.** An add without one is refused with
  `400`. A page loaded before this change sends none, so it cannot add a
  guest until it is reloaded.

## Alternatives rejected

- **A version check (If-Match, 412).** The form sends a hash of the bill
  rows and the save sends it back. It refuses B's save after any bill
  change by anyone, even a change to another cook, and it does not catch
  the #91 kind of bug. `meals.updated_at` cannot be the version, because
  sign-ups and guests change it, and a stored counter would be a cached
  money value (money rule 8).
- **Refuse a list that is missing a cook the server has.** It fixes only
  the first form of #135, and removing a cook would then need its own
  kind of row, which is an edit.
- **Accept both formats for one release.** Old pages would keep the bug,
  and an old page's full list would remove a cook a new page just added,
  which is the case this fixes. It means two ways to write bills, each
  with its specs and mutation runs, and a second deploy to remove one.
  With deploys on hold, "one release" has no end date.
- **JSON Patch (RFC 6902) itself.** Its paths point into a JSON document,
  and its `test` compares JSON values, so it cannot say that "5" and
  "5.00" are the same amount.
- **Amounts as JSON numbers.** A JSON number becomes a Float before the
  app sees it.

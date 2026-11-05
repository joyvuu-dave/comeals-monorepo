# ADR 0013: The shared screen in the Common House has its own login, which is not a resident

- **Status:** Accepted
- **Date:** 2026-11-05 (decisions made 2026-10-31 to 2026-11-04)

## Context

A screen in the Common House stays signed in, and anyone at dinner uses
it to sign people up. Until now it signed in with a resident's account.
So:

- The history named that resident for every change the screen made. It
  looked like one person signed up other people thousands of times.
- What the screen could do followed that resident. If they could settle
  a period, so could anyone who walked up to the screen.
- From 2018 to 2021 the code had the account's id written in it, to show
  its rows as "Common House" and hide its logout link. That was removed
  in 2021, and since then the old rows show the person's name.

## Decision

1. **The screen signs in as a `CommonHouseLogin`, not a `Resident`.** It
   has its own table with at most one row (`singleton_guard`, as on
   `communities`). Nothing that lists residents (cooks, sign-ups,
   balances) can list it, so none of those needs an exception for it.
   The row cannot be deleted, because the history names it.

2. **Only admins know its password.** A superuser sets it on the admin
   page "Common House Login". It must be at least 8 characters, and it
   has no reset link: the sign-in page says to ask an admin. Changing it
   signs the screen out everywhere (`keys_valid_since`, as for a
   resident). If the screen is signed out and no admin is around, a
   resident can sign in with their own account until an admin fixes it.

3. **It signs in on the resident sign-in form**, with the address
   `common-house@comeals.invalid` (`CommonHouseLogin::EMAIL`). The `.invalid`
   ending is kept by RFC 2606 from ever being a real domain, so no mail
   can reach anyone through it. No resident may have a `.invalid`
   address: `Resident#email_not_reserved` says so on the form, and the
   CHECK `residents_email_not_invalid_domain` holds it for writes that
   skip the model. So a sign-in with that address is always this login.
   The same rate limit as a resident sign-in applies.

4. **One token format and one `JwtAuth.authenticate` for both kinds of
   login.** The token names `resident_id` or `common_house_login_id`,
   never both. `authenticate` returns `JwtAuth::Login`, which is
   `T.any(Resident, CommonHouseLogin)`, so Sorbet refuses a call that
   only a `Resident` has.

5. **`ApiController` asks two questions.** `current_login` is whoever
   signed in. `current_resident_api` is that login only when it is a
   resident. `authenticate` needs a login. An action that needs a person
   reads `current_resident_api` and answers 403 when it is nil
   (`not_a_resident_api`).

6. **The screen may do everything a signed-in resident may, except two
   things:** settle a period (and preview a settlement), and read "which
   resident am I" (`GET /residents/id`). Both answer **403, not 401**:
   the web app treats every 401 as "signed out" and would show the
   sign-in page.

7. **The answer to the sign-in says what the screen is.** It has
   `username: "Common House"` and `common_house: true`, and no
   `resident_id`. The web app keeps them in cookies. The headers then
   say "logout Common House", and `isCommonHouse()` hides the calendar
   feed links, because the screen has no feed of its own.

8. **The history names it "Common House"** (`CommonHouseLogin::NAME`).
   The audit row's author is the login (`user_type` "CommonHouseLogin").
   `AuditSerializer` does not pass the name to `ResidentNameShortener`,
   which would make it "Common H".

9. **The old rows are relabeled by a task, with the account and the
   cutoff as inputs.** `rake history:relabel_as_common_house` moves the
   history rows that `RESIDENT_ID` wrote before `BEFORE` to the login.
   The id and the date belong to a real person and are not in this
   public repo. `BEFORE` must name its zone, and must not be after the
   login was made. Without `WRITE=yes` the task only counts.

## Consequences

- Every new action needs one decision: may the screen do it? If it needs
  a person, it reads `current_resident_api` and answers 403 for the
  screen. The default, `authenticate`, lets the screen in.
- The screen's sign-in and history no longer depend on any resident's
  account. Retiring or renaming a resident does not change them.
- Every Common House history row older than the login came from the
  relabel task, because the task refuses a later cutoff. So the relabel
  can be undone exactly: move the Common House rows older than the
  login's `created_at` back to the resident.
- The relabel cannot tell which old rows the person made from their own
  phone with the same account. Those rows are relabeled too.

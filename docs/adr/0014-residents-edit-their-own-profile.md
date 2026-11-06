# ADR 0014: Residents edit their own name, email and vegetarian setting

- **Status:** Accepted
- **Date:** 2026-11-06 (decisions made 2026-11-05)

## Context

Until now only an admin could change anything about a resident. A
resident who moved to a new email, or stopped eating meat, had to ask an
admin. The admin then edited the resident on the admin site.

The email is also the name a resident signs in with. So a mistake in it
can lock a resident out.

## Decision

1. **A signed-in resident can change their own name, email and
   vegetarian setting.** The "profile" link in the calendar header opens
   a form (`/calendar/:type/:date/profile/edit`). It is a draft with a
   Save button, like the other calendar forms (ADR 0006). The server
   saves the whole form in one transaction: all of it is saved, or none
   of it (`ProfileUpdate`). The model's checks run, so the rules are the
   ones the admin form has: a name no other resident has, and an email
   no other resident has.

2. **Only a resident has a profile.** The Common House login is not a
   resident (ADR 0013). The calendar shows it no profile link, and the
   server answers it 403.

3. **A new email is used only after the resident opens a link sent to
   it.** Until then the address waits in `residents.pending_email`, and
   the old address still signs in. A link sent to a wrong address is
   never opened, so a typo cannot lock anyone out. The link works once,
   for 24 hours, and only the newest link works (`EmailChange`). The
   database keeps only the SHA-256 digest of its token, as for a
   password reset. When the link is opened, the address is checked
   again: an admin may have given it to someone else in the meantime.
   The form has "Send the link again" for a link that did not arrive or
   expired. Saving the old address again takes the change off.

4. **No password is asked for any of it.** Being signed in is enough.
   The old address gets a notice when a change of email is asked for,
   and that notice is the only warning. So a person who uses a device
   someone else left signed in can change that resident's email to their
   own, open the link, and then reset the password. The resident sees
   the notice, and an admin can put the address back.

5. **An adult edits the name and vegetarian setting of each child in
   their unit who has no email** (`Resident#children_i_can_edit`). A
   child with no email cannot sign in, so without this only an admin
   could change them. A child with an email signs in and edits only
   their own profile. A child edits no one else.

6. **The birthday is not on the profile.** It sets the price of every
   dinner that is not settled yet, so changing it changes what people
   owe. An admin still sets it.

## Consequences

- The three email change columns are secret in the same way as the
  reset token columns: left out of the admin pages, the CSV and the JSON
  download (`config.filter_attributes`, `Resident::SECRET_COLUMNS`).
- A profile save and "Send the link again" can email an address the
  person typed, so both share a limit of 20 an hour per IP address
  (`config/initializers/rack_attack.rb`).
- A name change shows on every screen at once (`LiveUpdate.residents`),
  and the header's short name changes after the save.
- The history page shows each person's name as it is now. After a name
  change, their old changes show the new name too.

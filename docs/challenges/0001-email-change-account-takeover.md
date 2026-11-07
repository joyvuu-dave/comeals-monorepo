---
id: 1
title: An email change can take over an account
area: security
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - app/views/resident_mailer/email_change_notice_email.text.erb
  - app/services/email_change.rb
---

# An email change can take over an account

## The challenge

Someone who has a resident's signed-in device for one minute must not be able to take the account away from them for good.

## The case that breaks it

1. A resident is signed in on a phone or laptop that someone else can pick up.
2. That person opens the profile and changes the email to their own address. No password is asked (ADR 0014, the owner's choice on 2026-11-05).
3. They click the link that arrives in their own inbox. The email is now theirs.
4. They use "forgot password" with the new address and set a new password.
5. The real resident gets the notice at the old address. It says to sign in and put the old address back. But the password has changed, so they cannot sign in. Only an admin can fix it.

## Where we stand

- The notice to the old address has no link that undoes the change. It says "sign in, open your profile, and put this address back, or ask an admin" (`app/views/resident_mailer/email_change_notice_email.text.erb`).
- An email change waits for a one-use link sent to the new address, which works for 24 hours (`app/services/email_change.rb`, `docs/adr/0014-residents-edit-their-own-profile.md`).
- No password is asked for any profile change. This was decided, and this challenge does not reopen it.

## Options

1. **A "this wasn't me" link in the notice.** One click undoes the change, puts the old address back, signs out every session, and blocks email changes for that resident for a day. It needs a second token, sent only to the old address. It does not ask for a password.
2. **Wait before a change takes effect.** The new address works only 24 hours after the link is clicked, and the old address can cancel during that time. This is slower for an honest change.
3. **Ask for the password on an email change only.** Declined by the owner on 2026-11-05 ("don't ask for their password when they are changing stuff").

My recommendation is option 1.

## History

- 2026-11-07: Opened, from the talk after the profile feature shipped in v625.

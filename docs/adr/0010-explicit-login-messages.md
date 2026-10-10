# ADR 0010: Login and password reset say whether an email belongs to a resident

- **Status:** Accepted
- **Date:** 2026-10-09
- **Issue:** #126 (the list of decisions after the 2026-09-27 test review)

## Context

The login page and the password reset page give one answer when no
resident has the typed email, and a different answer when one does:

| Page                                     | No resident has the email              | A resident has the email                                                                                                                                |
| ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Login (`POST /residents/token`)          | "No resident with email <email>"       | "Incorrect password"                                                                                                                                    |
| Reset (`POST /residents/password-reset`) | "No resident with that email address." | "Check your email.", or the `503` when the mail could not be sent, or the #105 answer that names a field on the resident's row and says to ask an admin |

So anyone can find out whether an email belongs to a resident. The
usual rule for these two pages (OWASP's authentication and forgot
password guides) is the opposite: give the same words, in the same time,
whether or not the email is known.

## Decision

Keep the answers as they are. This is a community decision, made on
2026-10-09: residents did not like being told only that "the email or
the password" was wrong, without knowing which one. When the page says
which one is wrong, a resident who typed the wrong email sees that at
once and tries their other address.

The rate limits in `config/initializers/rack_attack.rb` still slow down
anyone who checks many emails: 20 logins per 5 minutes and 10 reset
requests per hour, from one IP address.

The code next to each of these answers points to this ADR, so nobody
"fixes" them by accident.

## Consequences

- A stranger can check whether an email belongs to a resident, up to the
  rate limits above. That tells them a person lives in the community. It
  does not sign them in: they still need the password, or the person's
  inbox for a reset link. A resident who chose a blank password (allowed
  on purpose, `Api::V1::ResidentsController#password_new`) can be signed in with
  the email alone, but that is true whatever the error messages say.
- If this is ever changed, the words alone are not enough. Login checks a
  password only when a resident has the email, and the reset mail is
  sent inside the request, so the answer also takes longer when the
  email is known. The two answers that only a known email can get (the
  `503` and the #105 answer) would need to go too, and the #105 answer is
  the only thing that tells a resident with a broken row to ask an admin.

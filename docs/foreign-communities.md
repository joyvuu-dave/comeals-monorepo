# Foreign communities — notes for a future discussion

Status: internal note, 2026-08-16. Not a GitHub issue yet. The plan is to
discuss non-US support together with the work to set up a community from
scratch (the setup wizard idea), as one bundled discussion.

## What is already settled

**Phone numbers need no migration, ever.** They are stored as E.164
(`+15105552671`, commit c5599b2), and that form carries its own country
code. The only US assumptions are how plus-less input is read
(`config/initializers/phonelib.rb`) and which numbers display in local
style (`app/helpers/phone_display_helper.rb`).

**The phone fix, when a non-US community exists:** add
`communities.country` — ISO 3166-1 alpha-2, `NOT NULL`, default `'US'`,
CHECK constraint `^[A-Z]{2}$`, validated against Phonelib's country data
(no new gem). Drop the global `Phonelib.default_country` and pass the
country per call: `Phonelib.parse(input, community.country)`. An AdminUser
without a community falls back to the singleton community's country.

**The country lives on Community, not Resident.** A resident with a
foreign number just types the `+`.

## The hard part is currency, not phones

`cap` is dollars, `balance_tag` prints "$", and the bill input grammar
assumes dollars and cents. Currency must be its own column and its own
decision. Never infer it from the country code — Canada and the US share
a phone plan but not a dollar.

## Why this waits

Deferring costs nothing: the stored phone data is already
country-independent, and no US-only choice made today gets more expensive
to undo later. Building the country column alone, before the currency
discussion, risks giving one column two meanings.

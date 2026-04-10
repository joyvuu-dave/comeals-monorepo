# Collection Workflow

## Purpose

This document captures the workflow for actually moving money once a reconciliation has been calculated. Reconciliation tells us *who* owes *whom* and *how much*. Collection is the follow-up: physically (or digitally) transferring the money to settle the balances.

This is a separate workflow from reconciliation calculation. They share state (the reconciliation balances), but the activities are distinct: one happens at a moment in time (compute the numbers), the other unfolds over days or weeks (collect from each person, pay out to each person).

The word "collection" is used loosely here to cover both directions — collecting from people who owe AND paying out to people who are owed. From the collector's perspective, both are the same activity: working through the balance list and settling each row.

## Background

Right now the app has no support for collection at all. Once a reconciliation is finalized, the person responsible for collection (often an admin, but not necessarily) is on their own. They print out the balances, walk around with a notebook, collect checks/cash from people who owe, write checks to people who are owed, and check things off as they go.

Some collection cycles take days. Some never fully complete (someone forgets, moves out, or is just hard to reach). The current process has no way to track partial state, no way to remind people, and no way to confirm everyone's settled up.

## The workflow as practiced

1. Reconciliation is run and finalized.
2. Balances are published to residents (currently via email).
3. The collector walks the published list, contacts each person who owes, collects payment.
4. The collector walks the published list of people owed, pays them out.
5. Throughout the process, the collector mentally tracks who's been handled (or scribbles on paper).
6. Eventually (days or weeks later), all balances are settled.
7. Sometimes the collector loses track of who they've collected from, or pays the same person twice, or forgets to collect from one person.

## Pain points

- **No tracking state.** Everything is in the collector's head (or on a piece of paper).
- **No partial completion.** A reconciliation is either "done" (calculations finalized) or "active" — no in-between for "calculations done, still collecting money."
- **No reminders.** People who haven't paid get no automated nudge.
- **No payment automation.** Every payment is a manual cash/check/Venmo transaction handled out-of-band.
- **No history of payments.** When and how each person paid isn't recorded.

## Improvement ideas

### 1. MVP: Manual paid/paid-out tracking

The simplest valuable thing: add a checkbox or "Mark Paid" button next to each row in the Settlement Balances panel. The collector clicks it as they collect from (or pay out to) each person.

**Schema:** A `paid_at` timestamp on `reconciliation_balance` (nullable; null = not yet settled, set = settled at this time).

**UI:** Each row in the Settlement Balances panel gets a "Mark Paid" button (or checkbox). Clicking sets `paid_at`. Once set, the row visually distinguishes itself (greyed out, checkmark, etc.).

**Why a timestamp over a boolean:** Same reasoning as `finalized_at` for reconciliations. A timestamp gives you "yes/no AND when," supports audit trails, and matches Rails idioms.

**Why "paid" works for both directions:** Whether the resident is owed or owes, the action from the collector's perspective is the same — "this balance has been settled." The label "Paid" is overloaded but readable in both contexts.

**Limitations of the MVP:**
- Manual click per row, no automation
- Doesn't help residents directly — only helps the collector
- No reminder system
- No payment integration

But it's the smallest change that captures the most basic state we need. It also lays the groundwork for everything else. Even if no other collection feature ever ships, this alone unblocks the collector and gives them a digital record.

**Priority:** Build this first.

### 2. Two distinct lifecycle states: `finalized_at` vs `settled_at`

Once we have per-balance `paid_at`, the natural derived state for the reconciliation is "has every balance been paid?" When all `reconciliation_balances` for a reconciliation have `paid_at` set, the reconciliation is **fully settled**.

Optionally store this as a `settled_at` timestamp on the reconciliation (set automatically when the last balance is marked paid). This gives us two distinct lifecycle states:

- **`finalized_at`:** Calculations are locked. No more meal additions/removals. (From the reconciliation workflow doc.)
- **`settled_at`:** All balances have been paid out. Money is fully settled.

A reconciliation goes: created → finalized → settled → done. The settled state is rarely reversed (you don't "un-pay" someone), but it's not strictly immutable either.

**Priority:** Tightly coupled with the MVP. Probably implement together.

### 3. Automated payment requests (the long-term vision)

The aspiration: instead of the collector manually walking around, the system sends each person who owes a "please pay" request, and confirms the payment automatically when it arrives. The dream end-state goes further: once collection is complete, payouts to people who are owed happen automatically too.

**Constraints:**

- **Minimize KYC burden.** We want to avoid Comeals being classified as a money services business with heavy compliance obligations. Some lightweight identity verification for participants is acceptable; full custodial money handling is not.
- **Low cost.** Meals cost a few dollars; payment processing fees can't eat the balance. For reference: checkbook.io was evaluated and ruled out at $2000/month — that's a non-starter for a community app.
- **Social trust assumed.** This is a co-housing community. Residents know each other. Heavy fraud-prevention machinery is overkill.

#### The fundamental asymmetry: collection vs payout

Collection and payout are different problems with different difficulty levels.

**Collection is easy.** Anyone can pay you money. They don't need an account with you. They click a link, type a card or bank info, money arrives. Stripe has multiple products that support this (Invoicing, Payment Links, Checkout). No setup required for the payer.

**Payout is hard.** To send money to someone, you need to know *where* to send it AND that person needs *some kind of relationship* with the payment processor (so they can be held accountable, comply with anti-money-laundering rules, etc.). There's no Stripe product that lets you say "send $30 to alice@example.com" with no further setup. *Someone* needs to register *somewhere*.

This asymmetry forces a decision: how much onboarding are we willing to require from residents in exchange for how much automation?

#### Stripe products that matter for us

- **Stripe Invoicing** — Hosted invoices sent via email. Recipients pay with card or bank (ACH). Money lands in the sender's Stripe balance. ~0.4% per invoice (capped at $2) on top of payment fees. Built-in reminders and dunning.
- **Stripe Payment Links** — Even simpler. Create a URL, share it, person pays. No customer object, no tracking. Free to use; just payment fees.
- **Stripe Connect Express** — Lightweight onboarding for people who need to receive money. They give Stripe their legal name, DOB, last 4 SSN, and bank account once via a hosted form. Stripe handles the rest. ~5-10 minute one-time setup per recipient.
- **Stripe Connect Standard** — Full Stripe account, heavy onboarding. Overkill for individual cooks.
- **ACH Debit pricing** — 0.8% capped at $5. For a $40 balance, that's $0.32. For $400, $3.20. Compare to card: 2.9% + $0.30 = $1.46 on $40, $11.90 on $400. **ACH is dramatically cheaper for our use case** and is the natural choice for non-time-sensitive transfers between people who have bank accounts.

#### Approach A: Informal payment links (no third-party integration)

Each resident saves their preferred payment method on their profile (Venmo username, Zelle email, etc.). When the reconciliation is published, each person owing money gets an email like:

> Hi Alice, you owe $42.50 for meals through March 31. Please send to Bob via Venmo: @bob-collector

For people owed money, the email says:

> Hi Charlie, you're owed $30 for meals through March 31. Bob will send via your preferred method (Zelle: charlie@example.com).

The collector still has to manually mark each balance as paid once they verify it on Venmo / their bank statement. **Cost: zero.** **Compliance burden: zero.** **Manual work: significantly reduced** — the email step is automated, the collector just confirms.

This is the cheapest possible improvement and requires no Stripe relationship at all.

#### Approach B: Stripe Invoicing (collection-only automation)

**Setup:** The reconciler creates a Stripe account (individual / sole proprietor — no business required). Done. One person, one signup.

**Flow per reconciliation:**

1. System creates a Stripe Customer for each resident who owes money
2. System creates a Stripe Invoice for each owed balance
3. Stripe emails the hosted invoice with a "Pay" button
4. Recipients pay via ACH or card
5. Money lands in the reconciler's Stripe balance
6. System receives `invoice.paid` webhooks and marks the corresponding `reconciliation_balance` as `paid_at` automatically
7. Reconciler withdraws funds to their bank account
8. Reconciler manually distributes to cooks via Venmo/Zelle/check (the payout side stays manual)

**Matches the ideal of "one signup":** ✅ One signup, ✅ invoices sent, ❌ automatic payouts

**Cost:** ~$0.50/payer (ACH) or ~$1.50/payer (card). For 12 owers, ~$6-18 per reconciliation.

**Compliance burden:** Just the reconciler. They provide identity info and bank account to Stripe. That's it.

**Effort to build:** Low. Stripe Invoicing API is straightforward. The hard parts are the customer creation flow and webhook handling for payment confirmations.

**Note on terminology:** "Invoice" carries B2B/B2C implications and possibly tax/legal weight. Stripe uses "invoice" as the product name, but our user-facing language can call them "payment requests" — closer to the peer-to-peer reality and less likely to confuse people.

#### Approach C: Stripe Connect Express with 100% adoption (the full automation dream)

The end-state vision: every unit has a designated payment representative with a Stripe Connect Express account. Once that's in place, reconciliations become almost trivially easy — the collection workflow effectively *disappears*.

**The architecture:**

Comeals becomes a Stripe Connect platform. Each unit designates one resident as their "payment representative." That person completes Stripe Connect Express onboarding once: legal name, DOB, last 4 SSN, bank account info. Stripe verifies them. Their Express account is now linked to the unit in the Comeals database.

This onboarding is a one-time, ~5-10 minute thing per unit. Once it's done, the unit can be both **charged** and **paid** through Stripe automatically forever.

**The reconciler's experience at reconciliation time:**

1. **Day 0, morning:** Click "Create Reconciliation," set the cutoff date.
2. **Day 0:** Review the auto-generated balances, mismatch warnings, and statistical outliers (the stuff in `RECONCILIATION_WORKFLOW.md`). Catch any errors. Iterate if needed.
3. **Day 0:** Click "Finalize." Calculations are now locked.
4. **Day 0:** Click "Settle Reconciliation." Big red button. Confirm dialog.
5. **Days 1-4:** *Nothing happens at the reconciler's level.* The system processes in the background.
6. **Day 5-ish:** Email arrives: "Reconciliation #6 fully settled."

That's the reconciler's entire job. ~15 minutes of attention on Day 0, then nothing.

**What's actually happening behind the scenes:**

1. System computes per-unit balances by rolling up resident-level balances
2. For each unit with a **negative balance** (owes money): create a Stripe ACH debit charge against their Express account's bank info, with the platform as the destination
3. For each unit with a **positive balance** (is owed money): nothing yet — wait for funds to clear
4. Webhooks fire as charges process. Some succeed quickly, some take 3-4 business days for ACH to clear
5. System monitors charge status. If all succeed, proceed. If any fail, halt and notify the reconciler
6. Once all charges have cleared: system creates Stripe Connect transfers from the platform's balance to each unit-with-positive-balance's Express account
7. Express accounts auto-payout to the recipient's bank account (typically same day or next)
8. Each `reconciliation_balance` gets `paid_at` set automatically as its corresponding charge or transfer completes
9. When the last balance settles, the reconciliation gets `settled_at`. Done.

End-to-end timeline: roughly **Day 0 to Day 5-7**. Not instant — ACH clearance is the constraint, not the system. Card debits would be Day 0 to Day 1 but with ~3-4× higher fees.

**Per-unit vs per-resident balance roll-up (a design decision worth flagging):**

Currently `reconciliation_balance` is per resident. With this Stripe flow, money moves at the **unit** level (because Stripe Express accounts are per-unit). This raises a question: do we keep per-resident balances and roll up at settlement, or change the data model to be per-unit?

**Recommendation:** keep per-resident balances as the source of truth, roll up to per-unit only for the actual money movement. Reasons:

- The per-resident granularity is real information — the admin still wants to see "Alice owes $30, Bob owes $5, even though their unit owes $35 net."
- The roll-up is trivial: `SUM(amount) GROUP BY unit_id`
- The unit-level "settlement intent" can be a derived/computed value that's only persisted at the moment of settlement
- This preserves all the existing UX while adding the per-unit settlement layer

The model gains a new concept: a **settlement intent** per unit per reconciliation, which is what actually gets charged/paid via Stripe. The per-resident balances stay as the underlying ledger.

**Edge cases that need real engineering (the hidden complexity):**

The "happy path" is short. The failure paths are where the real work lives. Each of these is solvable but needs UI and process design:

- **Failed charges.** ACH can fail (insufficient funds, account closed, dispute, etc.). The system has to: detect via webhook, halt disbursements (you can't pay out money you don't have), notify the reconciler, provide a UI to retry or fall back to manual collection for that unit.
- **Disputes / reversed ACH.** ACH debits can be reversed by the customer for up to 60 days. If a charge clears, you disburse, and then 30 days later the charge is reversed — the platform is on the hook. Stripe handles the mechanics but the platform needs to either hold a small reserve, accept the exposure, or delay disbursements until a shorter "dispute cooling period" (e.g., 7 days) passes.
- **A unit's Express account fails verification.** Stripe sometimes can't verify accounts (mismatched info, identity issues). That unit can't participate until it's resolved. UI to flag this and a fallback ("this unit pays manually this cycle").
- **Someone moves out mid-cycle.** A resident leaves; their unit's Express account closes or stops responding. Their balance has to be paid by someone else in the unit, or written off. Process needed.
- **Tax reporting.** Stripe issues 1099-K forms to connected accounts that hit IRS thresholds. For a cook who receives $200/reconciliation × 6 reconciliations = $1,200/year, they'll likely get a 1099-K. **Residents need to be told upfront** so they're not surprised. This might create a tax-filing burden some residents object to.
- **Platform compliance.** Comeals takes on Stripe's platform agreement and some responsibility for the connected accounts. Not huge, but real — Comeals goes from "a Rails app" to "a Rails app that's also a Stripe platform with TOS and customer support obligations."

**Matches the ideal:** ❌ One-time signup per unit (not just the reconciler), ✅ invoices sent automatically, ✅ payouts automatic

**Cost:** Same payment fees as Approach B. Connect itself doesn't add fees for transfers between accounts on the same platform.

**Effort to build:** High. Connect onboarding flow, account linking, charge logic, transfer logic, webhook handling for both directions, all the edge case UI.

**The honest pitch to a unit's representative:** "Do this 5-minute setup once, and your unit will never have to chase reimbursement (or chase down owers) again. Money will move automatically within a week of every reconciliation."

#### The first-reconciliation hurdle (change management, not engineering)

Approach C works cleanly for **new** communities adopting Comeals from scratch: "Welcome. To participate in the meal program, your unit needs to set up payment receiving. Here's the link." Five minutes per unit. Done. The requirement is enforced as part of joining the community.

For an **existing** community migrating from a paper-and-Venmo system, it's harder. You'd need to: announce the change with lots of lead time, get every unit onboarded *before* the first new-system reconciliation, have a manual fallback for units that drag their feet, and probably do at least one reconciliation in "hybrid mode" (some Express, some manual).

This is a change-management problem, not a technical one. The tech is the easy part.

#### Approach D: Hybrid (opt-in Express, manual fallback)

Same as Approach B (Stripe Invoicing for collection), plus: any cook who *wants* automated payouts can opt in by doing the Express onboarding. Cooks who don't sign up still get paid manually.

This is the path of least resistance for an existing community. The benefits of Approach C accumulate gradually as more cooks opt in, and there's no flag day where everyone has to be onboarded at once.

**Effort to build:** Medium. You're building both flows, but you can ship them in stages.

#### Recommendation

**Start with Approach B (Stripe Invoicing only).** Why:

- One Stripe signup (the reconciler), zero changes for residents
- Solves the biggest pain (collection) immediately
- Free for the reconciler beyond payment fees
- Validates whether residents will actually pay through the system before committing to Connect
- The collection side is the harder behavior change anyway — once people are used to "pay your reconciliation invoice via the link in the email," the rest is gravy
- Doesn't require Comeals to become a Stripe platform, keeping compliance simple
- The data model and webhook plumbing for B is reusable when graduating to C

**Then evaluate Approach D (hybrid) or jump to Approach C (full automation) based on community appetite.** If cooks are enthusiastic about auto-payouts, build Express onboarding as an opt-in. If a new community is willing to mandate Express signup as part of joining, go straight to C.

**Approach C is the dream end-state for steady-state operation**, especially for new communities where 100% adoption can be required from day one. The reconciler becomes purely a calculation reviewer; they never touch money.

**Approach A (informal Venmo/Zelle links) remains a viable zero-cost starting point** for communities not ready for any Stripe relationship at all. Worth keeping as a fallback configuration even after B/C exist.

### 4. Self-service confirmation

Distribute the work: instead of the collector marking each person off, each resident gets a link in their email like "click here to confirm you've paid." Their click marks `paid_at`.

This shifts the marking burden from the collector to the residents. Combined with Approach A (manual payment links), it's a near-automated workflow with no payment integration:

1. Resident receives email: "You owe $42, send to Bob via Venmo @bob-collector. [Click here once you've paid]"
2. Resident pays via Venmo (out of band)
3. Resident clicks the confirmation link, marking themselves as paid in the system
4. Collector sees the dashboard update in real-time
5. Once everyone's clicked, the reconciliation is fully settled

**Risk:** People might lie or forget. The collector might want to verify before fully trusting self-confirmation. But for a co-housing community with high trust, it's probably fine — and the audit trail (item 7) makes any disputes traceable.

### 5. Reminders

Automated email reminders to people whose `paid_at` is still null after N days. "Hey Alice, it's been 7 days since the reconciliation, you still owe $15."

Tunable cadence (daily? weekly? escalating?). Stops once the balance is marked paid. Should be opt-out so people aren't accidentally annoyed.

### 6. Per-resident payment method preferences

Each resident's profile includes their preferred payment method(s):

- Venmo username
- Zelle email
- PayPal email
- Cash / check (manual handling expected)

Used to populate the email instructions automatically. **Required** for any of the automation approaches above — without it, the system doesn't know how to tell people where to send money.

### 7. Audit trail

Important for shared finances. Record:

- Who marked each balance as paid (collector? resident self-service?)
- When
- Any notes ("paid in cash on Tuesday")
- History of changes (if a balance was marked paid then unmarked)

A separate `payment_events` table logging each transition could work. Or just `paid_at`, `paid_by_id`, `paid_note` columns on `reconciliation_balance`. The latter is simpler and probably sufficient.

### 8. Bulk operations

Common patterns the collector might want one-click for:

- "Mark all residents in unit B as paid" — units sometimes settle as a group
- "Mark all guest debits as paid" — handled separately from residents
- "Mark everyone with a small balance (< $5) as paid" — for cleanup of trivial balances

Speeds up the collector's work for common cases. Cosmetic but appreciated.

### 9. Reconciliation status dashboard

Currently the admin sees a reconciliation as a static thing. With collection tracking, the show page should display:

- "8 of 12 balances settled, $42 outstanding"
- A visual progress bar
- A list of who's still outstanding (with optional "remind" buttons)

Lets the collector see at a glance where things stand without scanning the whole balance table.

### 10. Write-offs

Edge case but real: someone moves out without settling, or a small balance just isn't worth chasing. Need a way to mark a balance as "written off" — distinct from "paid" — with a reason.

Could be a `written_off_at` timestamp + `write_off_reason` column. But this raises a non-trivial accounting question: the rounded balances currently sum to exactly zero. If you write off $5 of debt, the books no longer balance. Does the written-off amount become a community-wide loss redistributed to remaining members? Or just absorbed as a one-time accounting event?

This is a real accounting design problem and deserves its own thinking. **Defer until the basics are working.**

### 11. The "collector" as a formal role

Currently no formal "collector" role exists — it's just whoever decided to do the work. Worth considering whether this should become a first-class concept:

- A reconciliation has a designated collector (a `Resident` reference, not necessarily an admin)
- The collector gets the dashboard view, the reminder controls, etc.
- Could rotate between residents reconciliation-to-reconciliation
- Could even support multiple collectors (one for collection, one for payouts)

Doesn't change the data model much — it's a single reference column. But it formalizes who's responsible.

## Recommended sequence

1. **MVP: per-balance paid/paid-out tracking** (item 1) + **per-reconciliation `settled_at`** (item 2). Tightly coupled, build together. Unblocks the collector immediately and lays the data model foundation for everything else.
2. **Per-resident payment method preferences** (item 6). Required for any informal automation. Cheap to add.
3. **Approach A: Informal payment links** (item 3, Approach A). Free, immediate UX win once item 6 is in place. Good fallback even after Stripe ships.
4. **Self-service confirmation** (item 4). Combined with #3, gives a near-automated workflow with no payment integration.
5. **Reminders** (item 5). Quality-of-life addition.
6. **Audit trail** (item 7). Important for shared finances, but not blocking.
7. **Reconciliation status dashboard** (item 9). Visual polish.
8. **Bulk operations** (item 8). Helpful but not essential.
9. **Collector as formal role** (item 11). Worth considering if multi-person collection becomes common.
10. **Approach B: Stripe Invoicing** (item 3, Approach B). The first real Stripe integration. One signup (reconciler), automated collection, manual payout. Solid 80% solution.
11. **Approach D: Stripe Invoicing + opt-in Express** (item 3, Approach D). Layer Connect Express on top of B as cooks opt in. Builds momentum toward full automation without a flag day.
12. **Approach C: Full Stripe Connect Express with 100% adoption** (item 3, Approach C). The dream end-state. Best fit for new communities that can mandate Express signup as part of joining. Replaces nearly the entire collection workflow.
13. **Write-offs** (item 10). Defer until the accounting questions are clearer.

## Open questions

- **Will the community actually use any of this, or will the collector keep using paper?** Worth a conversation before building beyond the MVP. The MVP is so cheap it's worth doing regardless.
- **Who's "the collector"?** Currently no formal role exists. Should we add one (item 11), or just assume it's the admin who finalizes the reconciliation?
- **Privacy:** should one resident's "outstanding balance" be visible to other residents? In a small co-housing community, probably yes. In a larger community, maybe not.
- **International expansion:** payment methods are heavily country-specific. The Stripe-based approaches assume US ACH rails. A European community might need SEPA. Likely a per-community configuration concern that affects which approach is even available.
- **Trust level for self-service confirmation:** is "click to confirm I've paid" trustworthy enough, or do we want collector verification as a second step?
- **For Approach C: does Comeals want to be a Stripe Connect platform?** This is a meaningful organizational decision, not just a technical one. Becoming a platform means signing Stripe's platform agreement, taking on some compliance obligations, and providing customer support for the connected accounts. Worth deciding deliberately before building.
- **For Approach C: how does the platform handle the ACH dispute window?** ACH debits can be reversed for up to 60 days. If the platform disburses immediately after charges clear and a dispute happens later, the platform is on the hook. Hold a reserve? Delay disbursements 7 days? Accept the exposure and hope?
- **For Approach C: who's the unit's "payment representative" when there are multiple residents?** Probably whoever volunteers, but this needs a UI for designation and a process for changing it.
- **For Approach C: how do we handle the 1099-K tax reporting surprise for cooks?** Stripe will issue 1099-K forms to recipients above the threshold. Residents need to be told upfront so they can plan, and some may object on principle.
- **For Approach C: chicken-and-egg for existing communities.** A new community can mandate Express signup as part of joining. An existing community has to migrate. What's the migration playbook? Probably a hybrid period (Approach D) before full cutover.

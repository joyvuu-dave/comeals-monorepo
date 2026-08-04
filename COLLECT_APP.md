# Collect — iPhone App for Reconciliation

## Purpose

This document is the design home for **Collect**, a dedicated iPhone app for performing reconciliations in Comeals. It captures the rationale for going native, the API contracts the iOS client will consume, the backend refactor work that unblocks those contracts, the iOS-side implementation approach, and the order we plan to build things in.

See `RECONCILIATION_WORKFLOW.md` and `COLLECTION_WORKFLOW.md` for the workflow ideas Collect is expressing. Those docs are the _product_ layer; this doc is the _implementation_ layer.

## Why a dedicated native app?

The alternative was to add reconciliation tooling to the existing ActiveAdmin pages (or into the `comeals-monorepo` SPA). Going native is more work. Here's why it's worth it anyway:

- **The form factor matches the activity.** The reconciler is literally walking around the co-housing community — standing at doors, collecting cash and checks, marking things off. Desktop web is the wrong form factor. It's why the current process uses paper. A mobile app is ergonomically correct here, not just a "nice to have native feel" argument.

- **Native polish matters for infrequent, high-stakes workflows.** Reconciliation happens every few weeks. When it does, it needs to feel good and be error-resistant. SwiftUI gives us haptics on "mark paid," swipe-to-complete, fluid navigation, pull-to-refresh — all painful to replicate in ActiveAdmin or in a responsive mobile web view.

- **The API decoupling is independently valuable.** Outlier detection, mismatch warnings, and paid-tracking logic should live as clean JSON endpoints on the Rails backend regardless — not tangled into ActiveAdmin view code. Building Collect _forces_ that discipline. Even if the Swift app stalls halfway through, the Rails work is a strict improvement.

- **Scope is contained enough to actually finish.** "Perform a reconciliation end-to-end" is one well-defined workflow — maybe 6–10 screens, no sprawling feature set. That's exactly the right size for a first iPhone app. Compare to trying to port the whole `comeals-monorepo` SPA, which is far too large for a first project.

- **ActiveAdmin stays.** Collect is _additive_ — the reconciler's workflow-specific view. ActiveAdmin remains the general-purpose admin tool for residents, units, meal debugging, and everything else. The two coexist.

## Scope

**Collect is:** the reconciler's end-to-end workflow tool. Preview a reconciliation, review mismatch warnings and outliers, create it, then track collection/payout as balances get settled.

**Collect is not:** a general-purpose admin app, a replacement for the `comeals-monorepo` SPA, or a place for residents to manage their own attendance. Those jobs belong to the existing surfaces.

Rough screen list (to be fleshed out as we design):

- **Login** — email + password, stores token in Keychain
- **Home** — current unreconciled state summary + list of recent reconciliations
- **Preview** — date picker for cutoff, then the big one: summary, meals, balances, warnings
- **Meal detail** — drill-down from the meal list (who ate, bill breakdown)
- **Warning detail** — drill-down for each warning with "jump to meal" action
- **Create confirmation** — big button with confirm dialog. This is the point of no return: creating the reconciliation locks it.
- **Collection tracking** — after the reconciliation exists, a list of balances with swipe-to-mark-paid
- **Settings** — logout and not much else

## Authentication

**Reuse the existing JWT auth.** The Rails backend already has this mechanism for the React frontend — `POST /api/v1/residents/token` exchanges email + password for a stateless JWT (`JwtAuth.encode`, signed HS256, embeds `resident_id` and `iat`). The iOS app reuses this flow exactly:

1. First launch: login screen collects email + password
2. App calls `POST /api/v1/residents/token`, receives `{ token, resident_id, ... }`
3. Token is stored in the iOS Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
4. Every subsequent request sends `Authorization: Bearer <stored_token>`
5. On `401`, drop the token and bounce back to login

Send the token in the `Authorization` header, not as a `?token=` query param. The backend accepts the query param as a fallback (`ApiController#resolve_current_session!`), but URLs end up in logs and history; a new client should use the header.

The token has no expiry. Revocation happens when the resident's password changes, which bumps `residents.keys_valid_since` and invalidates every token issued before it (`app/services/jwt_auth.rb`).

**Do not build on the legacy `Key` model.** `Key.find_by(token:)` still exists as a fallback for sessions issued before the JWT deploy, and issue #42 tracks removing it. A new client that used it would be building on the path scheduled for deletion.

**No OAuth, no separate mobile auth system.** One auth mechanism, two clients.

**Permissioning for v1: any authenticated resident can preview and create.** Small trusted community, financial data is already visible in email reports, no need to gate further. If we later want to restrict, add a `residents.can_reconcile` boolean column — that's the seam to target.

## Money representation

**All money values in JSON are string-encoded decimals.** Examples: `"42.50"`, `"7.08"`, `"-23.10"`.

- **JSON floats are unacceptable for financial data** — silent precision loss, rounding surprises. Violates CLAUDE.md's "never use Float for money" rule at the wire-format level.
- **Integer cents were considered and rejected.** Per-meal `unit_cost` is an intermediate full-precision value (only final balances get Hamilton-rounded to cents), so an integer-cents scheme doesn't fit uniformly across the response.
- **String decimals decode cleanly into Swift's `Decimal` type** via a custom `JSONDecoder` strategy, preserving the full precision from the Rails `BigDecimal`.

On the iOS side, all money is `Decimal`. A thin `Money` wrapper type may be justified later for formatting, but the underlying storage is always `Decimal`.

## API contracts

### `GET /api/v1/reconciliations/preview`

**The foundational read endpoint.** Returns everything the iOS app needs to render the preview screen: summary stats, the full meal list, per-resident and per-unit balances, and any data-quality warnings.

**Query parameters:**

- `cutoff` (required, ISO date `YYYY-MM-DD`): meals on or before this date are included. Must match `Reconciliation#assign_meals` semantics exactly, which are `date <= cutoff` **and** `date < today` — a meal on a day that is not yet over is never swept, whatever the cutoff says (issue #3). A cutoff of today or later is not a valid reconciliation, so the endpoint should reject it the same way the model does.

**Auth:** `Authorization: Bearer <jwt>` header (see the Authentication section). No `token` query parameter.

**Error responses** (following existing API conventions):

- `400 bad_request` — missing or malformed `cutoff`
- `401 unauthorized` — missing/invalid token
- `200` with empty arrays — no meals match (valid state, not an error)

**Response body:**

```json
{
  "cutoff_date": "2026-04-10",
  "generated_at": "2026-04-10T14:32:15Z",
  "summary": {
    "meal_count": 47,
    "total_cost": "1247.83",
    "earliest_meal_date": "2026-03-15",
    "latest_meal_date": "2026-04-09",
    "residents_affected": 23,
    "units_affected": 12
  },
  "meals": [
    {
      "id": 1234,
      "date": "2026-04-09",
      "description": "Thursday Dinner",
      "total_cost": "127.50",
      "effective_cost": "127.50",
      "capped": false,
      "subsidized": false,
      "total_multiplier": 18,
      "unit_cost": "7.08",
      "attendee_count": 15,
      "guest_count": 3,
      "cooks": [{ "resident_id": 42, "name": "Alice", "bill_amount": "127.50" }]
    }
  ],
  "balances": {
    "residents": [
      {
        "resident_id": 42,
        "name": "Alice",
        "unit_id": 5,
        "unit_name": "5B",
        "amount": "47.32"
      }
    ],
    "units": [
      {
        "unit_id": 5,
        "unit_name": "5B",
        "amount": "47.32",
        "resident_count": 2
      }
    ]
  },
  "warnings": [
    {
      "id": "bill_with_no_attendees:meal=1234:bill=789",
      "kind": "bill_with_no_attendees",
      "severity": "warning",
      "meal_id": 1234,
      "title": "Bill with no attendees",
      "body": "Charlie submitted a $45.00 bill for a meal with zero attendees."
    },
    {
      "id": "attendance_without_bill:meal=1235",
      "kind": "attendance_without_bill",
      "severity": "warning",
      "meal_id": 1235,
      "title": "Attendance without bill",
      "body": "7 residents signed up to eat, but no bill was submitted."
    },
    {
      "id": "zero_bill_not_flagged:meal=1236:bill=791",
      "kind": "zero_bill_not_flagged",
      "severity": "info",
      "meal_id": 1236,
      "title": "Bill of $0 not flagged as 'no cost'",
      "body": "David submitted a $0.00 bill but didn't mark it as a no-cost meal."
    }
  ]
}
```

#### Design decisions worth preserving

**Warnings at the top level, not inlined per meal.** Cross-referenced by `meal_id`. This lets the iOS app render them in a dedicated "Issues to Review" screen _and_ render inline badges on the meal list using the same data. Strictly more flexible than either alternative on its own.

**`warning.id` is deterministic, not a UUID.** Format: `kind:meal=N:bill=N`. Critical for SwiftUI `List`/`ForEach` diffing — the same warning on a re-fetch gets the same identifier, so the list animates smoothly instead of rebuilding.

**Backend owns the copy (`title` + `body`).** The iOS app does not template warning text. Wording can be updated server-side without shipping a new binary. The iOS app renders whatever strings the backend sends.

**`kind` is a string enum the client switches on** (for icons, colors, tap navigation). Known v1 kinds:

- `bill_with_no_attendees`
- `attendance_without_bill`
- `zero_bill_not_flagged`

**The iOS client MUST render unknown kinds gracefully**, falling back to `title`/`body`. This is the forward-compatibility hinge — it lets us add `cost_outlier`, `date_outlier`, `cook_attending_zero_multiplier`, etc. in future iterations without breaking deployed binaries.

**No `direction` field on balances.** The sign of `amount` is the source of truth: negative = owes, positive = owed. A redundant `direction` field would be noise.

**Both per-resident and per-unit balances in one response.** The reconciler's mental model toggles between them; sending both avoids a round-trip.

**No pagination.** Typical reconciliations are <100 meals. Revisit if we ever hit 500.

**Dates:** `cutoff_date`, `earliest_meal_date`, `latest_meal_date`, and each meal's `date` are calendar-dates (`YYYY-MM-DD`). `generated_at` is a full ISO 8601 timestamp (`YYYY-MM-DDTHH:MM:SSZ`). Two different Swift decode strategies, one per field type.

### Future endpoints (to be designed)

Contracts below are placeholders — each gets its own sketch when we get to it.

- `POST /api/v1/reconciliations` — commit a previewed reconciliation at a given cutoff. Equivalent to today's `rake reconciliations:create`, but with the cutoff passed in instead of hardcoded to yesterday. Creating it is the lock: the row refuses update and destroy from that moment, and its meals' bills, attendance, and guests are frozen by database triggers. There is no separate finalize step and no unfinalize — see `RECONCILIATION_WORKFLOW.md` item 4.
- `POST /api/v1/reconciliations/:id/balances/:balance_id/mark_paid` — sets `paid_at` on a `reconciliation_balance`, automatically triggers derived `settled_at` on the reconciliation if all balances are now paid. Both columns are still unbuilt; see `COLLECTION_WORKFLOW.md` items 1 and 2.
- `GET /api/v1/reconciliations/:id` — historical view for a created reconciliation. What Collect's collection screen will consume.

## Backend implementation strategy

### The blocker: `Reconciliation#after_create :finalize`

The existing `Reconciliation` model computes and persists in one atomic act: an `after_create` callback runs `assign_meals` then `persist_balances!`. That means today you cannot compute a reconciliation's balances _without_ persisting records. (The callback is named `finalize`, which predates the decision not to have a separate finalize step. The name is about finishing the create, not about a lifecycle state.)

For the preview endpoint to work, we need a way to run the calculation **without side effects**. That is the whole point of the preview: `review → create` as two steps, with the review carrying no commitment. Creating stays one atomic, locking act — we are not splitting it.

### Plan: extract `ReconciliationCalculator` PORO

```
ReconciliationCalculator.new(community:, cutoff_date:).call
  # => {
  #   meals: [...],
  #   resident_balances: [...],
  #   unit_balances: [...],
  #   summary: {...}
  # }
```

- Takes a community and cutoff date, queries the exact same meal scope as `assign_meals`:
  `Meal.unreconciled.joins(:bills).where(date: ..cutoff_date).where(date: ...Time.zone.today).distinct`
- Runs the existing settlement math including Hamilton's method
- Returns a structured result — zero persistence, zero side effects
- `Reconciliation#settlement_balances` becomes a thin wrapper delegating to the PORO

The refactor should be near-pure: the existing `reconciliation_spec.rb` model specs are the safety net and should pass unchanged.

### Plan: `ReconciliationWarnings` module

Separate concern from the calculator. Takes the same meal collection and returns an array of warning hashes:

```
ReconciliationWarnings.new(meals:).call
  # => [
  #   { id: "bill_with_no_attendees:meal=...", kind: ..., ... },
  #   ...
  # ]
```

v1 checks:

1. **`bill_with_no_attendees`** — a bill exists on a meal with zero `meal_residents` and zero `guests`
2. **`attendance_without_bill`** — a meal has attendees but no bills
3. **`zero_bill_not_flagged`** — a bill has `amount == 0` but `no_cost == false`

The preview controller composes both: calculator for the money, warnings for the data quality, then renders a single JSON response.

### Preview controller sketch

```ruby
# app/controllers/api/v1/reconciliations_controller.rb
class Api::V1::ReconciliationsController < ApiController
  def preview
    cutoff = Date.iso8601(params.require(:cutoff))
    result = ReconciliationCalculator.new(
      community: Community.instance,
      cutoff_date: cutoff
    ).call
    warnings = ReconciliationWarnings.new(meals: result[:meals]).call
    render json: PreviewSerializer.new(result, warnings, cutoff).as_json
  rescue Date::Error, ActionController::ParameterMissing
    render json: { error: "cutoff must be an ISO date (YYYY-MM-DD)" },
           status: :bad_request
  end
end
```

Thin. All the real work lives in the PORO, the warnings module, and the serializer.

## iOS implementation strategy

### Stack

- **Swift 6.3**, strict concurrency on (`SWIFT_STRICT_CONCURRENCY = complete`)
- **SwiftUI**, `@Observable` for view models (not `ObservableObject`)
- **async/await** throughout — no completion handlers anywhere
- **`URLSession`** directly for networking — no Alamofire or similar
- **Keychain Services** directly for token storage — no wrapper libraries
- **`JSONDecoder`** with a custom `Decimal` strategy for money fields
- **No third-party dependencies.** A ~10-endpoint single-purpose app doesn't need them. Easier to maintain, faster to build, no dependency hell.

### Project layout (tentative)

```
Collect/
├── CollectApp.swift              # @main entry
├── Models/                       # Codable structs matching API contracts
│   ├── ReconciliationPreview.swift
│   ├── Warning.swift
│   └── Money.swift               # typealias or thin wrapper around Decimal
├── Networking/
│   ├── APIClient.swift           # URLSession + token plumbing
│   ├── Endpoints.swift           # enum of endpoints with their decoders
│   └── KeychainStore.swift
├── Features/
│   ├── Login/
│   ├── Preview/
│   ├── MealDetail/
│   └── Collection/
└── Shared/                       # reusable views (WarningBadge, MoneyLabel, etc.)
```

### First iOS milestone: render the raw JSON

Before designing any real UI, the first iOS milestone is "hit the preview endpoint and render the raw JSON as a plain text dump." This proves the contract works end-to-end — login flow, Keychain storage, token injection, decoding, error handling. Real UI comes after.

## Sequencing

Build the Rails work fully before opening Xcode. **This is the single most important decision in this document.** If we start writing Swift against a shifting API, we will spend half the iOS time reworking code every time a JSON shape changes. Worse, the iOS work is more fun than the backend work, and the backend work is where the value is.

1. **Extract `ReconciliationCalculator` PORO** — near-pure refactor, existing specs as safety net
2. **Write `ReconciliationWarnings` module** with the three v1 warning kinds + unit specs
3. **Write `Api::V1::ReconciliationsController#preview`** action + serializer
4. **Request specs for the preview endpoint:** happy path, no meals, each warning kind in isolation, mixed warnings, cutoff in the future, invalid date, unauthenticated
5. **Hand-test with `curl`** to verify the JSON actually matches the sketch above
6. **Open Xcode.** New SwiftUI project, strict concurrency on, build the "render raw JSON" throwaway screen
7. **Real iOS UI** for the preview screen
8. **Loop back to backend** for the create endpoint, then alternate backend → iOS from there

## Open questions

- **Apple Developer Program ($99/year).** Needed for running on a physical device for more than 7 days, and for TestFlight distribution. Budget accordingly if the plan is real production use.
- **Who is the collector?** Always one person, or does it rotate? Affects whether Collect needs a "handoff" story or can assume single-user. Tied to the "collector as formal role" idea in `COLLECTION_WORKFLOW.md` §11.
- **Does Collect also support the resident view** (checking your own balance, seeing what you owe for the current cycle)? Or is that strictly the `comeals-monorepo` SPA's job? This is a scope decision that should be made before the login flow is built — it affects whether "who am I as a logged-in user" matters beyond auth.
- **Offline support.** For walking-around-the-community use, partial connectivity is realistic. Should `paid_at` marks be queued locally and synced, or require live connection? Defer until the collection screens are being designed, but decide early enough that the data layer can still change.
- **Push notifications.** "Reminder: reconciliation X has 3 unpaid balances" would be useful. Requires APNs setup, which is non-trivial. Not v1.
- **Permissioning:** any authenticated resident can preview, or restricted? See auth section. Flagging for future discussion if the community grows or the role becomes more formal.

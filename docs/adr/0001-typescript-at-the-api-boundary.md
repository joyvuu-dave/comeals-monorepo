# ADR 0001: TypeScript at the API Boundary

- **Status:** Accepted
- **Date:** 2026-04-28

## Context

The frontend is ~48 `.js` / `.jsx` files: a React 19 SPA with MobX stores, talking to Rails 8.1 over `/api/v1/*`. There's no static typing today.

A full TypeScript rewrite is tempting but mostly cosmetic for this codebase:

- The financial logic — the part where types prevent disasters — lives in Rails with `BigDecimal` and DECIMAL(12, 8) columns. JS never does the arithmetic.
- MobX `types.model(...)` stores type cleanly only with non-trivial scaffolding. A sloppy migration leaks `any` and produces worse-than-JS code.
- One developer. The cost is weeks; the realized safety is small.

The bugs that _actually_ bite a thin client like this one happen at the API seam: a serializer drops a field, renames it, or starts returning `null` where it didn't before, and the SPA quietly breaks.

## Decision

Adopt TypeScript **only at the API boundary**. Do not migrate stores, components, or helpers wholesale.

Concretely:

1. Add a permissive `tsconfig.json` at the repo root with `allowJs: true` and `checkJs: false`. Vite already understands `.ts`/`.tsx` with no plugin.
2. Create `app/frontend/src/types/api.ts` as the single source of truth for serializer response shapes. Each interface mirrors one `app/serializers/*.rb` file. Update them in lockstep when serializers change.
3. Create `app/frontend/src/helpers/api.ts`: thin typed wrappers around `axios`, one function per endpoint, returning `Promise<T>` where `T` comes from `types/api.ts`. Replace bare `axios({ method, url, data })` call sites incrementally.
4. Money on the wire is typed as `MoneyString` (a branded `string`), never `number`. Rails serializes `BigDecimal` as a JSON string; treating it as a number on the JS side is a bug class we want the compiler to forbid.
5. New frontend code is written in `.ts` / `.tsx` by default. Existing `.js` / `.jsx` files are converted opportunistically when touched, never as a migration project.

## Consequences

**Catches at compile time:**

- Serializer field renames, removals, or nullability changes that the SPA hasn't picked up.
- `bill.amount + 1` (or any number arithmetic on money strings).
- Wrong request payload shapes (missing `socket_id`, wrong key names).
- 404-prone endpoint typos.

**Does not catch:**

- MobX store internals (action signatures, derived state).
- Component prop mismatches.
- JSX typos.

That's the deliberate trade — ~50% of TS's safety for ~10% of the cost.

**Operational rules:**

- When a Rails serializer changes, the matching interface in `types/api.ts` must change in the same PR. This is enforced mechanically, not by discipline: `spec/serializers/api_contract_spec.rb` (Rails side) and `tests/unit/api_contract.test.ts` (TS side, plus a compile-time manifest check) both assert against `tests/fixtures/api_contract.json`, so drift on either side fails `bin/check`. Changing a serializer's fields means updating the fixture, which forces the interface update — and vice versa.
- `MoneyString` values are parsed (`new BigNumber(...)` or similar) at the point of use, never coerced with `+` or `Number(...)`.
- Do not flip `checkJs` on globally. If a specific `.js` file is worth checking, opt it in with a `// @ts-check` header.

## Migration order

1. Land `tsconfig.json`, `types/api.ts` (seeded with `MealForm`, `Bill`, calendar event shapes), `helpers/api.ts` skeleton. No call sites changed yet.
2. Convert the meal-edit flow's axios calls to go through `api.meals.*`. This is the highest-leverage area because it touches money.
3. Repeat per feature area as appetite allows: residents, guests, reservations, calendar.
4. Stores and components stay `.js` / `.jsx` until there's a reason to touch them. No migration deadline.

## Alternatives considered

- **Full TS migration.** Rejected: cost dominates benefit for a single-developer codebase where the financial correctness layer is in Rails.
- **JSDoc + `checkJs` everywhere.** Rejected: the syntax for generics and unions in JSDoc is verbose enough that you may as well write TS. Keeps the worst of both worlds.
- **Runtime validation (Zod / io-ts) at the API boundary.** Considered. Stronger guarantee — catches drift the compiler can't see — but adds a runtime dependency and a parse step on every response. Revisit if a serializer-drift bug ships to production despite the type-level boundary.

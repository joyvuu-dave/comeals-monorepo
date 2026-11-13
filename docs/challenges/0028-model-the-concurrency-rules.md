---
id: 28
title: Model the concurrency rules
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-13
watches:
  - docs/adr/0003-concurrency-on-the-money-path.md
  - models/MealSettlement.tla
  - models/SerializableOnly.tla
  - models/MealEventList.tla
  - docs/models.md
---

# Model the concurrency rules

## The challenge

Show, for every order in which writes can happen, that the concurrency rules keep the money rules true.

## The case that breaks it

The race specs try a few orders on purpose. ADR 0003 records that the settlement lock and the trigger were each tried alone and neither one worked; it took all three pieces. A fourth piece, or a change to one, could open an order no spec tries.

## Where we stand

- The protocol is described in `docs/adr/0003-concurrency-on-the-money-path.md` and pinned by the race specs in `spec/db/`.
- TLA+ models in `models/`, checked by TLC in `bin/check` and the CI `models` job (`bin/tla-check`, `docs/models.md`). Each case is a config file whose first line says whether the properties must hold or which one must fail.
- `models/MealSettlement.tla` is today's protocol: one or two settlements, an API writer, an admin form and a psql writer at READ COMMITTED, with the settlement lock, the compare-and-swap and the trigger each a switch. TLC finds that a settled dinner's rows never change and that a dinner is settled once. It finds a failing order when the trigger is taken away, when it is the `FOR KEY SHARE` trigger from before 2026-10-16, or when it looks only at `NEW.meal_id`, and when the compare-and-swap is taken away from settlements run at READ COMMITTED.
- At SERIALIZABLE the model needs only the trigger for these two properties; the settlement lock and the compare-and-swap are not needed for them. ADR 0003 says the lock and the trigger each failed alone, but that test used the old `FOR KEY SHARE` trigger. `spec/db/settlement_without_its_lock_spec.rb` confirms this against a real PostgreSQL (2026-11-13): with the settlement's `FOR UPDATE` taken out, a raw write before or after the claim still leaves the stored balances matching the rows, and with the `FOR KEY SHARE` trigger every example fails.
- `models/SerializableOnly.tla` is challenge 2, option A, and `models/MealEventList.tla` is challenge 3. Each holds with the guarantees that design names, and fails without the one piece the design depends on.
- Not modelled: cancelling a dinner, corrections, the rules inside one dinner (seat limit, last open spot), and sizes above the ones in the case files.

## Options

1. **A TLA+ model of today's protocol:** a settlement, two sign-ups, an admin write and a psql write at READ COMMITTED, with the meal lock, the compare-and-swap and the trigger. TLC checks that a settled dinner never changes and that a settlement counts every row.
2. **Models of the designs in challenges 2 and 3,** assuming only the guarantees each design says it uses. If the property holds there, the locks are not needed under that design.

## Decision

Options 1 and 2 (the owner, 2026-11-12): a model of today's protocol that shows what fails with each piece removed, checked in `bin/check` and CI like the Dafny proofs, and models of the designs in challenges 2 and 3.

## History

- 2026-11-07: Opened.
- 2026-11-12: The owner chose options 1 and 2.
- 2026-11-12: Done. Three TLA+ models with 14 cases, checked by `bin/tla-check` in `bin/check` and CI.
- 2026-11-13: A spec against a real PostgreSQL agrees with the model about the settlement lock (challenge 2 has the details).

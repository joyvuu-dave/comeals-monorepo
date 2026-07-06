// TypeScript half of the API contract gate. The Rails half is
// spec/serializers/api_contract_spec.rb; both assert against the same
// fixture, tests/fixtures/api_contract.json.
// See docs/adr/0001-typescript-at-the-api-boundary.md.
//
// Two enforcement layers:
//   - Compile time: each manifest literal below must list exactly the keys of
//     its interface — the mapped type `{ [K in keyof T]-?: true }` rejects
//     both missing and extra keys — so `npm run typecheck` fails when
//     types/api.ts changes without this file.
//   - Runtime: the manifests must equal the fixture, so `npm test` fails when
//     the fixture changes (i.e. when the Rails side of the contract moved).

import { describe, expect, it } from "vitest";

import contractJson from "../fixtures/api_contract.json";
import type {
  Guest,
  MealForm,
  MealFormBill,
  MealFormGuest,
  MealFormResident,
  MealResident,
} from "../../app/frontend/src/types/api";

const contract: Record<string, string[]> = contractJson;

function keysOf<T>(manifest: { [K in keyof T]-?: true }): string[] {
  return Object.keys(manifest).sort();
}

const manifests: Record<string, string[]> = {
  Guest: keysOf<Guest>({
    id: true,
    meal_id: true,
    resident_id: true,
    vegetarian: true,
    created_at: true,
  }),
  MealForm: keysOf<MealForm>({
    id: true,
    description: true,
    max: true,
    closed: true,
    closed_at: true,
    date: true,
    reconciled: true,
    next_id: true,
    prev_id: true,
    bills: true,
    residents: true,
    guests: true,
  }),
  MealFormBill: keysOf<MealFormBill>({
    resident_id: true,
    amount: true,
    no_cost: true,
  }),
  MealFormGuest: keysOf<MealFormGuest>({
    id: true,
    meal_id: true,
    resident_id: true,
    vegetarian: true,
    created_at: true,
  }),
  MealFormResident: keysOf<MealFormResident>({
    id: true,
    meal_id: true,
    name: true,
    attending: true,
    attending_at: true,
    late: true,
    vegetarian: true,
    can_cook: true,
    active: true,
  }),
  MealResident: keysOf<MealResident>({
    id: true,
    meal_id: true,
    resident_id: true,
    late: true,
    vegetarian: true,
    created_at: true,
  }),
};

describe("types/api.ts matches tests/fixtures/api_contract.json", () => {
  it("covers every entry in the contract fixture", () => {
    expect(Object.keys(manifests).sort()).toEqual(Object.keys(contract).sort());
  });

  for (const [name, keys] of Object.entries(manifests)) {
    it(`${name} keys match the fixture`, () => {
      expect(keys).toEqual([...contract[name]].sort());
    });
  }
});

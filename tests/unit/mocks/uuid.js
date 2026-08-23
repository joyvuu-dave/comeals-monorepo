// Deterministic ids in place of crypto.randomUUID(). Use it with:
//
//   import { stubRandomUUID } from "../mocks/uuid.js";
//   stubRandomUUID();
//
// The counter runs for the life of the test file (vitest isolates
// modules per file), so ids are "test-uuid-1", "test-uuid-2", ... in
// creation order.
import { vi } from "vitest";

let counter = 0;

export function stubRandomUUID() {
  vi.spyOn(crypto, "randomUUID").mockImplementation(
    () => "test-uuid-" + ++counter,
  );
}

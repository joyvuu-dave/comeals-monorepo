// The shared uuid mock: deterministic ids. Use it with the redirect
// form:
//
//   vi.mock("uuid", () => import("../mocks/uuid.js"));
//
// The counter runs for the life of the test file (vitest isolates
// modules per file), so ids are "test-uuid-1", "test-uuid-2", ... in
// creation order.
import { vi } from "vitest";

let counter = 0;

export const v4 = vi.fn(() => "test-uuid-" + ++counter);

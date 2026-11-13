import { expect } from "vitest";

// The request config a calendar form's save sends with its body: an
// Idempotency-Key holding a UUID (use_request_key.ts, ADR 0015).
export const KEYED = {
  headers: {
    "Idempotency-Key": expect.stringMatching(
      /^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/,
    ),
  },
};

// The request config of a delete, whose key is built from the id.
export function deleteKeyed(key) {
  return { headers: { "Idempotency-Key": `"${key}"` } };
}

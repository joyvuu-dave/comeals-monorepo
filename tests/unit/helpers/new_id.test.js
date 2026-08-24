import { describe, it, expect, vi, afterEach } from "vitest";
import { newId } from "../../../app/frontend/src/helpers/new_id";

const V4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe("newId", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("uses crypto.randomUUID when the context has it", () => {
    vi.spyOn(crypto, "randomUUID").mockReturnValue("from-random-uuid");
    expect(newId()).toBe("from-random-uuid");
  });

  it("builds a version 4 UUID from getRandomValues when randomUUID is missing", () => {
    // Plain http from a LAN address: no randomUUID on crypto at all.
    const original = crypto.randomUUID;
    Object.defineProperty(crypto, "randomUUID", {
      value: undefined,
      configurable: true,
      writable: true,
    });
    try {
      const ids = new Set(Array.from({ length: 50 }, newId));
      ids.forEach((id) => expect(id).toMatch(V4));
      expect(ids.size).toBe(50);
    } finally {
      Object.defineProperty(crypto, "randomUUID", {
        value: original,
        configurable: true,
        writable: true,
      });
    }
  });
});

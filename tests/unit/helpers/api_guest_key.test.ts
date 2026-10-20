// A guest add sends an Idempotency-Key header: a quoted string (RFC
// 9651), new for each add. This build's server ignores the header. The
// next release's server refuses a guest add without one (its
// app/services/guest_add.rb), so a page loaded from this build keeps
// adding guests after that deploy.
import { describe, expect, it, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("uuid", () => import("../mocks/uuid.js"));

import axios from "axios";

import { api } from "../../../app/frontend/src/helpers/api";

describe("api.meals.residents.guests.add", () => {
  it("sends a new quoted Idempotency-Key with each add", async () => {
    await api.meals.residents.guests.add(7, 3, {
      vegetarian: false,
      socketId: "s1",
    });
    await api.meals.residents.guests.add(7, 3, {
      vegetarian: true,
      socketId: "s1",
    });

    const calls = vi.mocked(axios).mock.calls.map((call) => call[0]);
    expect(calls.map((config) => config.headers)).toEqual([
      { "Idempotency-Key": '"test-uuid-1"' },
      { "Idempotency-Key": '"test-uuid-2"' },
    ]);
    expect(calls[0]).toMatchObject({
      method: "post",
      url: "/api/v1/meals/7/residents/3/guests",
      data: { vegetarian: false, socket_id: "s1" },
    });
  });
});

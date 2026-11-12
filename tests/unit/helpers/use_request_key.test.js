import { describe, it, expect } from "vitest";
import { renderHook } from "@testing-library/react";
import useRequestKey, {
  requestKeyHeaders,
} from "../../../app/frontend/src/helpers/use_request_key";

function keyOf([, config]) {
  return config.headers["Idempotency-Key"];
}

// ADR 0015: a save sent again after no answer must carry the same key,
// and a save of changed fields a new one.
describe("useRequestKey", () => {
  it("returns the body unchanged, with a quoted UUID as the key", () => {
    const { result } = renderHook(() => useRequestKey());
    const body = { title: "Movie Night" };

    const [sent, config] = result.current(body);

    expect(sent).toBe(body);
    expect(config.headers["Idempotency-Key"]).toMatch(
      /^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/,
    );
  });

  it("keeps the key while the body is the same, across renders", () => {
    const { result, rerender } = renderHook(() => useRequestKey());

    const first = keyOf(result.current({ title: "A", day: 1 }));
    rerender();
    const second = keyOf(result.current({ title: "A", day: 1 }));

    expect(second).toBe(first);
  });

  it("makes a new key when the body changes, and another when it changes back", () => {
    const { result } = renderHook(() => useRequestKey());

    const a = keyOf(result.current({ title: "A" }));
    const b = keyOf(result.current({ title: "B" }));
    const backToA = keyOf(result.current({ title: "A" }));

    expect(b).not.toBe(a);
    // Only the last save's key is kept. The save of A after B is a new
    // request: B may have been saved over it.
    expect(backToA).not.toBe(a);
    expect(backToA).not.toBe(b);
  });

  it("gives each form its own key", () => {
    const one = renderHook(() => useRequestKey()).result.current;
    const two = renderHook(() => useRequestKey()).result.current;

    expect(keyOf(one({ title: "A" }))).not.toBe(keyOf(two({ title: "A" })));
  });
});

describe("requestKeyHeaders", () => {
  it("puts the key between double quotes, as a Structured Field string", () => {
    expect(requestKeyHeaders("delete-event-7")).toEqual({
      "Idempotency-Key": '"delete-event-7"',
    });
  });
});

import { describe, it, expect } from "vitest";
import { renderHook } from "@testing-library/react";
import {
  StoreContext,
  useStore,
} from "../../../app/frontend/src/helpers/store_context.jsx";

describe("useStore", () => {
  it("returns the store the provider holds", () => {
    const store = { name: "the store" };
    const wrapper = ({ children }) => (
      <StoreContext.Provider value={store}>{children}</StoreContext.Provider>
    );

    const { result } = renderHook(() => useStore(), { wrapper });

    expect(result.current).toBe(store);
  });

  it("throws outside a provider, instead of handing back null", () => {
    expect(() => renderHook(() => useStore())).toThrow(
      "useStore called outside <StoreContext.Provider>",
    );
  });
});

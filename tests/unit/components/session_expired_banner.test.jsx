import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import SessionExpiredBanner from "../../../app/frontend/src/components/app/session_expired_banner.jsx";

// The `logout: false` annotation stops MobX from wrapping the spy in an
// action, which would hide it from toHaveBeenCalled.
function makeStore(overrides = {}) {
  return observable(
    {
      authExpired: false,
      logout: vi.fn(),
      ...overrides,
    },
    { logout: false },
  );
}

function renderBanner(store) {
  return render(
    <StoreContext.Provider value={store}>
      <SessionExpiredBanner />
    </StoreContext.Provider>,
  );
}

describe("SessionExpiredBanner", () => {
  it("renders nothing while the session is good", () => {
    const { container } = renderBanner(makeStore());
    expect(container).toBeEmptyDOMElement();
  });

  it("shows the banner and a Sign in button after a 401", () => {
    renderBanner(makeStore({ authExpired: true }));
    expect(
      screen.getByText("Heads up — you've been signed out."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });

  it("appears when the store flips to expired", () => {
    const store = makeStore();
    const { container } = renderBanner(store);
    expect(container).toBeEmptyDOMElement();

    act(() => {
      runInAction(() => {
        store.authExpired = true;
      });
    });
    expect(
      screen.getByText("Heads up — you've been signed out."),
    ).toBeInTheDocument();
  });

  it("Sign in logs the session out", () => {
    const store = makeStore({ authExpired: true });
    renderBanner(store);
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));
    expect(store.logout).toHaveBeenCalledTimes(1);
  });
});

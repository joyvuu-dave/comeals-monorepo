import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route } from "react-router";
import { fakeLocation } from "../helpers/fake_location.js";

// date_box.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

// The History page's code is its own file (a chunk). After a deploy, a
// meal page loaded before it asks for a chunk the server no longer has,
// and the import fails. Here the import always fails, the way a 404
// does.
vi.mock("../../../app/frontend/src/components/history/show.jsx", () => {
  throw new Error("no chunk");
});

import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { MEAL_EDIT_PATH } from "../../../app/frontend/src/routes.js";
import DateBox from "../../../app/frontend/src/components/meal/date_box.jsx";

function makeStore() {
  return observable(
    {
      mealLoading: false,
      communityToday: "2026-01-15",
      cancelledPending: false,
      meal: {
        id: 42,
        date: "2026-01-15",
        prevId: 41,
        nextId: 43,
        closed: false,
        reconciled: false,
        cancelled: false,
      },
      goToMeal: vi.fn(),
      teardownCalendarPage: vi.fn(),
      billsPendingFor: vi.fn(() => false),
      setCancelled: vi.fn(),
      sendBillsAgainBeforeClose: vi.fn(),
    },
    {
      goToMeal: false,
      teardownCalendarPage: false,
      billsPendingFor: false,
      setCancelled: false,
      sendBillsAgainBeforeClose: false,
    },
  );
}

describe("DateBox, when the History page's code fails to load", () => {
  let fake;

  beforeEach(() => {
    sessionStorage.clear();
    fake = fakeLocation();
    vi.stubGlobal("__BUILD_ID__", "test-build");
    // The page reloads only once the server answers (lazy_retry.ts).
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve({ ok: true, status: 200 })),
    );
  });

  afterEach(() => {
    fake.restore();
    sessionStorage.clear();
    vi.unstubAllGlobals();
  });

  // The same as the Calendar and the meal page (index.jsx): the page
  // reloads once to get the new build, and the bills saves on their way
  // are handed to the browser first (#150). It does not go to the
  // error page.
  it("sends the bills saves again, then reloads the page", async () => {
    const store = makeStore();
    render(
      <StoreContext.Provider value={store}>
        <MemoryRouter initialEntries={["/meals/42/edit/history/"]}>
          <Routes>
            <Route path={MEAL_EDIT_PATH} element={<DateBox />} />
          </Routes>
        </MemoryRouter>
      </StoreContext.Provider>,
    );

    await waitFor(() => {
      expect(fake.location.reload).toHaveBeenCalledTimes(1);
    });
    expect(store.sendBillsAgainBeforeClose).toHaveBeenCalledTimes(1);
    expect(
      store.sendBillsAgainBeforeClose.mock.invocationCallOrder[0],
    ).toBeLessThan(fake.location.reload.mock.invocationCallOrder[0]);
    expect(screen.getByText("Loading...")).toBeInTheDocument();
  });
});

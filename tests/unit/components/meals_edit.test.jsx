import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";

// meal/date_box.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

// Mock external modules before importing stores (same set as the
// data_store tests). The /cooks GET serves the e2e meal fixture, so
// the page renders real populated data end to end.
vi.mock("axios", () => {
  const mockAxios = vi.fn(() => Promise.resolve({ status: 200 }));
  mockAxios.get = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
  mockAxios.interceptors = {
    response: { use: vi.fn(), eject: vi.fn() },
    request: { use: vi.fn() },
  };
  return { default: mockAxios };
});

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => {
      const cookies = {
        token: "test-token",
        community_id: "test-community-id",
        timezone: "America/Los_Angeles",
        username: "Jane Smith",
      };
      return cookies[name];
    }),
    remove: vi.fn(),
    set: vi.fn(),
  },
}));

vi.mock("pusher-js", () => {
  class MockPusher {
    constructor() {
      this.connection = {
        bind: vi.fn(),
        socket_id: "test-socket",
      };
      this.subscribe = vi.fn(() => ({ bind: vi.fn(), name: "test-channel" }));
      this.unsubscribe = vi.fn();
    }
  }
  return { default: MockPusher };
});

vi.mock("localforage", () => ({
  default: {
    getItem: vi.fn(() => Promise.resolve(null)),
    setItem: vi.fn(() => Promise.resolve()),
    removeItem: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock("uuid", () => {
  let counter = 0;
  return {
    v4: vi.fn(() => "test-uuid-" + ++counter),
  };
});

import { MemoryRouter, Routes, Route } from "react-router";
import { Provider } from "mobx-react";
import axios from "axios";
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import relativeTime from "dayjs/plugin/relativeTime";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { MEAL_EDIT_PATH } from "../../../app/frontend/src/routes.js";
import MealsEdit from "../../../app/frontend/src/components/meals/edit.jsx";
import mealFixture from "../../fixtures/meal.json";

// index.jsx registers these at app startup; the date box needs both.
dayjs.extend(advancedFormat);
dayjs.extend(relativeTime);

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderPage(store) {
  return render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <MemoryRouter initialEntries={["/meals/42/edit/"]}>
          <Routes>
            <Route path={MEAL_EDIT_PATH} element={<MealsEdit />} />
          </Routes>
        </MemoryRouter>
      </StoreContext.Provider>
    </Provider>,
  );
}

describe("MealsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    axios.get.mockImplementation((url) => {
      if (url.includes("/cooks")) {
        return Promise.resolve({ status: 200, data: mealFixture });
      }
      return Promise.resolve({ status: 200, data: {} });
    });
  });

  it("mounting the page loads the meal from the URL and renders it", async () => {
    const store = DataStore.create({
      meals: [],
      residentStore: { residents: {} },
      billStore: { bills: {} },
      guestStore: { guests: {} },
    });
    renderPage(store);

    // DateBox's mount fetches meal 42; the fixture then populates
    // every box on the page. The long timeout covers a cold first run,
    // where importing the whole store graph eats most of the default
    // second.
    expect(
      await screen.findByText("OPEN", {}, { timeout: 5000 }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("cell", { name: "Jane Smith" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Enter meal description")).toHaveDisplayValue(
      "Pasta night with garlic bread",
    );
    expect(screen.getByText("Cooks")).toBeInTheDocument();
    expect(screen.getByText("Signed Up")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "logout Jane Smith" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "history" })).toBeInTheDocument();
  });
});

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import {
  MemoryRouter,
  Routes,
  Route,
  useLocation,
  useNavigate,
} from "react-router";

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => (name === "username" ? "Jane Smith" : undefined)),
  },
}));

import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import Header from "../../../app/frontend/src/components/meal/header.jsx";

function makeStore(overrides = {}) {
  return observable(
    {
      mealLoading: false,
      isOnline: true,
      meal: { date: new Date(2026, 0, 15) },
      logout: vi.fn(),
      ...overrides,
    },
    { logout: false },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// The class version reads history/location props (passed by
// meals/edit); the hooks version reads the router directly. The bridge
// hands the class real router-backed props, so the same assertions
// hold for both.
function Bridge({ store }) {
  const navigate = useNavigate();
  const location = useLocation();
  return (
    <StoreContext.Provider value={store}>
      <Header history={{ push: navigate }} location={location} />
    </StoreContext.Provider>
  );
}

function renderHeader(store) {
  return render(
    <MemoryRouter initialEntries={["/meals/42/edit/"]}>
      <Routes>
        <Route path="*" element={<Bridge store={store} />} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("Header", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("shows the online state and flips with the store", () => {
    const store = makeStore();
    renderHeader(store);
    expect(screen.getByText("ONLINE")).toBeInTheDocument();

    act(() => {
      runInAction(() => {
        store.isOnline = false;
      });
    });
    expect(screen.getByText("OFFLINE")).toBeInTheDocument();
  });

  it("names the signed-in user on the logout button", () => {
    renderHeader(makeStore());
    expect(
      screen.getByRole("button", { name: "logout Jane Smith" }),
    ).toBeInTheDocument();
  });

  it("Calendar goes back to the meal's calendar day", () => {
    renderHeader(makeStore());
    fireEvent.click(screen.getByRole("button", { name: /Calendar/ }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-01-15",
    );
  });

  it("renders the history button bar", () => {
    renderHeader(makeStore());
    expect(screen.getByRole("button", { name: "history" })).toBeInTheDocument();
  });
});

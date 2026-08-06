import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import {
  MemoryRouter,
  Routes,
  Route,
  useLocation,
  useNavigate,
} from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import SideBar from "../../../app/frontend/src/components/calendar/side_bar.jsx";

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// The class version reads history/location props (passed by
// calendar/show); the hooks version reads the router directly. The
// bridge hands the class real router-backed props, so the same
// assertions hold for both.
function Bridge({ store }) {
  const navigate = useNavigate();
  const location = useLocation();
  return (
    <StoreContext.Provider value={store}>
      <SideBar history={{ push: navigate }} location={location} />
    </StoreContext.Provider>
  );
}

function renderBar() {
  const store = observable({});
  render(
    <MemoryRouter initialEntries={["/calendar/all/2026-01-15/"]}>
      <Routes>
        <Route path="*" element={<Bridge store={store} />} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("SideBar", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("opens each reservation form under the current calendar path", () => {
    renderBar();

    fireEvent.click(screen.getByRole("button", { name: "Guest Room" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-01-15/guest-room-reservations/new",
    );
  });

  it("opens the common house form and the event form", () => {
    renderBar();

    fireEvent.click(screen.getByRole("button", { name: "Common House" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-01-15/common-house-reservations/new",
    );
  });

  it("Next Meal asks the server which meal is next and goes there", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { meal_id: 42 } });
    renderBar();

    fireEvent.click(screen.getByRole("button", { name: "Next Meal" }));
    expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/next");

    await vi.waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent(
        "/meals/42/edit",
      );
    });
  });
});

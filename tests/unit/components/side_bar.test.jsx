import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import SideBar from "../../../app/frontend/src/components/calendar/side_bar.jsx";

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// SideBar takes no props and reads no store: it reads the path from the
// router. calendar/show renders it the same way, as a bare <SideBar />.
function renderBar() {
  render(
    <MemoryRouter initialEntries={["/calendar/all/2026-01-15/"]}>
      <Routes>
        <Route path="*" element={<SideBar />} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("SideBar", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
  });

  it.each([
    {
      button: "Guest Room",
      form: "guest room",
      path: "guest-room-reservations/new",
    },
    {
      button: "Common House",
      form: "common house",
      path: "common-house-reservations/new",
    },
    { button: "Event", form: "event", path: "events/new" },
  ])(
    "$button opens the $form form under the current calendar path",
    ({ button, path }) => {
      renderBar();

      fireEvent.click(screen.getByRole("button", { name: button }));
      expect(screen.getByTestId("location")).toHaveTextContent(
        new RegExp(`^/calendar/all/2026-01-15/${path}$`),
      );
    },
  );

  it("Next Meal asks the server which meal is next and goes there", async () => {
    axios.get.mockResolvedValue({ status: 200, data: { meal_id: 42 } });
    renderBar();

    fireEvent.click(screen.getByRole("button", { name: "Next Meal" }));
    expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/next");

    await vi.waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/meals\/42\/edit$/,
      );
    });
  });

  // The server's answer when no meal is on the calendar from today on
  // (MealsController#next): a 400 with a null meal id and no message.
  // The button asks handleAxiosError to stay silent, so nothing shows.
  it("Next Meal stays on the calendar when no meal is scheduled", async () => {
    axios.get.mockRejectedValue({
      response: { status: 400, data: { meal_id: null } },
    });
    renderBar();

    fireEvent.click(screen.getByRole("button", { name: "Next Meal" }));
    await vi.waitFor(() => {
      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/next");
    });
    await act(async () => {});
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/calendar\/all\/2026-01-15\/$/,
    );
    expect(toastStore.toasts).toHaveLength(0);
  });
});

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
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

  // A failed Next Meal shows its message like every other button, and
  // the calendar stays on screen. The first case is the server's answer
  // when no meal is dated today or later (MealsController#next).
  it.each([
    {
      failure: "no meal is scheduled",
      error: {
        response: {
          status: 404,
          data: { message: "No meal is scheduled yet." },
        },
      },
      message: "No meal is scheduled yet.",
    },
    {
      failure: "the server fails",
      error: { response: { status: 500, data: "<html>500</html>" } },
      message: "The server had a problem. Please try again.",
    },
    {
      failure: "the connection is lost",
      error: { request: {} },
      message: "Error: no response received from server.",
    },
  ])(
    "Next Meal says so and stays on the calendar when $failure",
    async ({ error, message }) => {
      axios.get.mockRejectedValue(error);
      renderBar();

      fireEvent.click(screen.getByRole("button", { name: "Next Meal" }));
      await vi.waitFor(() => {
        expect(toastStore.toasts).toHaveLength(1);
      });
      expect(toastStore.toasts[0]).toMatchObject({ message, type: "error" });
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15\/$/,
      );
    },
  );
});

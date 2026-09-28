import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));

// toCommunityDayjs reads the community timezone from a cookie.
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = { timezone: "America/Los_Angeles" };

import axios from "axios";
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import MealHistoryShow from "../../../app/frontend/src/components/history/show.jsx";

// index.jsx registers this plugin at app startup; the "Do" ordinal in
// the date header needs it.
dayjs.extend(advancedFormat);

// A promise the test settles by hand, for answers that arrive late.
function deferred() {
  const d = {};
  d.promise = new Promise(function (resolve, reject) {
    d.resolve = resolve;
    d.reject = reject;
  });
  return d;
}

function history(date, items = []) {
  return { status: 200, data: { date: date, items: items } };
}

describe("MealHistoryShow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // The computer's zone is not the community's here, so a time read
    // in the computer's zone (the bug fixed in 4f912271) shows the wrong
    // hour and day on every machine, not only outside Pacific time.
    vi.stubEnv("TZ", "UTC");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("shows Loading, then the audit table", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        date: "2026-01-15",
        items: [
          {
            id: 1,
            user_name: "Jane Smith",
            description: "signed up",
            display_time: "2026-01-14T18:30:00Z",
          },
          {
            id: 2,
            user_name: "Bob Johnson",
            description: "added a guest",
            display_time: "2026-01-14T19:00:00Z",
          },
          // Already January 15 in UTC, still January 14 in the
          // community's zone.
          {
            id: 3,
            user_name: "Jane Smith",
            description: "went late",
            display_time: "2026-01-15T05:00:00Z",
          },
        ],
      },
    });
    render(<MealHistoryShow id="42" />);

    expect(screen.getByText("Loading...")).toBeInTheDocument();

    expect(await screen.findByText("Thu, Jan 15th")).toBeInTheDocument();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/42/history");

    expect(
      screen.getByRole("columnheader", { name: "User" }),
    ).toBeInTheDocument();
    expect(screen.getAllByRole("cell", { name: "Jane Smith" })).toHaveLength(2);
    expect(screen.getByRole("cell", { name: "signed up" })).toBeInTheDocument();
    expect(
      screen.getByRole("cell", { name: "added a guest" }),
    ).toBeInTheDocument();

    // The Time column is in the community's zone (America/Los_Angeles).
    const times = screen
      .getAllByRole("row")
      .slice(1)
      .map((row) => row.lastChild.textContent);
    expect(times).toEqual([
      "Wed Jan 14, 10:30 am",
      "Wed Jan 14, 11:00 am",
      "Wed Jan 14, 9:00 pm",
    ]);
  });

  it("says so when the history fails to load", async () => {
    axios.get.mockRejectedValue({ response: { status: 500, data: {} } });
    render(<MealHistoryShow id="42" />);

    expect(await screen.findByText(/failed to load/i)).toBeInTheDocument();
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
  });

  // The effect runs again when the id changes. An answer for the id
  // shown before must not replace the answer for the id shown now.
  it("drops an answer for an id it no longer shows", async () => {
    const first = deferred();
    const second = deferred();
    axios.get
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const { rerender } = render(<MealHistoryShow id="42" />);
    rerender(<MealHistoryShow id="43" />);
    expect(axios.get).toHaveBeenLastCalledWith("/api/v1/meals/43/history");

    await act(async () => second.resolve(history("2026-01-16")));
    await act(async () => first.resolve(history("2026-01-15")));

    expect(screen.getByText("Fri, Jan 16th")).toBeInTheDocument();
    expect(screen.queryByText("Thu, Jan 15th")).not.toBeInTheDocument();
  });

  it("drops a failure for an id it no longer shows", async () => {
    const first = deferred();
    const second = deferred();
    axios.get
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const { rerender } = render(<MealHistoryShow id="42" />);
    rerender(<MealHistoryShow id="43" />);

    await act(async () => second.resolve(history("2026-01-16")));
    await act(async () =>
      first.reject({ response: { status: 500, data: {} } }),
    );

    expect(screen.getByText("Fri, Jan 16th")).toBeInTheDocument();
    expect(screen.queryByText(/failed to load/i)).not.toBeInTheDocument();
  });

  // Only one answer is on screen at a time: the history for the id
  // shown now, or the failure to load it.
  it("a new id replaces an earlier failure, and a failure replaces an earlier history", async () => {
    axios.get.mockRejectedValueOnce({ response: { status: 500, data: {} } });
    const { rerender } = render(<MealHistoryShow id="42" />);
    expect(await screen.findByText("Failed to load history.")).toBeVisible();

    axios.get.mockResolvedValueOnce(history("2026-01-16"));
    rerender(<MealHistoryShow id="43" />);
    expect(await screen.findByText("Fri, Jan 16th")).toBeInTheDocument();
    expect(screen.queryByText(/failed to load/i)).not.toBeInTheDocument();

    axios.get.mockRejectedValueOnce({ response: { status: 500, data: {} } });
    rerender(<MealHistoryShow id="44" />);
    expect(await screen.findByText("Failed to load history.")).toBeVisible();
    expect(screen.queryByText("Fri, Jan 16th")).not.toBeInTheDocument();
  });
});
